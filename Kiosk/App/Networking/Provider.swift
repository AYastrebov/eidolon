import Foundation
import ISO8601DateFormatter
import Moya
import RxSwift
import Alamofire

class OnlineProvider<Target where Target: MoyaTarget>: RxMoyaProvider<Target> {

    let online: Observable<Bool>

    init(endpointClosure: MoyaProvider<Target>.EndpointClosure = MoyaProvider.DefaultEndpointMapping,
        requestClosure: MoyaProvider<Target>.RequestClosure = MoyaProvider.DefaultRequestMapping,
        stubClosure: MoyaProvider<Target>.StubClosure = MoyaProvider.NeverStub,
        manager: Manager = Alamofire.Manager.sharedInstance,
        plugins: [Plugin<Target>] = [],
        online: Observable<Bool> = connectedToInternetOrStubbing()) {

            self.online = online
            super.init(endpointClosure: endpointClosure, requestClosure: requestClosure, stubClosure: stubClosure, manager: manager, plugins: plugins)
    }
}

protocol ProviderType {
    var provider: OnlineProvider<ArtsyAPI> { get }
    var providersAuthorization: Bool { get }
}

protocol AuthorizedProviderType: ProviderType {
}

extension AuthorizedProviderType {
    var providersAuthorization: Bool { return true }
}


struct Provider: ProviderType {
    let provider: OnlineProvider<ArtsyAPI>
    var providersAuthorization: Bool { return false }
}

struct AuthorizedProvider: AuthorizedProviderType {
    let provider: OnlineProvider<ArtsyAPI>
}

private extension ProviderType {

    /// Request to fetch and store new XApp token if the current token is missing or expired.
    func XAppTokenRequest(defaults: NSUserDefaults) -> Observable<String?> {

        var appToken = XAppToken(defaults: defaults)

        // If we have a valid token, return it and forgo a request for a fresh one.
        if appToken.isValid {
            return just(appToken.token)
        }

        let newTokenRequest = self.provider.request(ArtsyAPI.XApp)
            .filterSuccessfulStatusCodes()
            .mapJSON()
            .map { element -> (token: String?, expiry: String?) in
                guard let dictionary = element as? NSDictionary else { return (token: nil, expiry: nil) }

                return (token: dictionary["xapp_token"] as? String, expiry: dictionary["expires_in"] as? String)
            }
            .doOn { event in
                guard case Event.Next(let element) = event else { return }

                let formatter = ISO8601DateFormatter()
                // These two lines set the defaults values injected into appToken
                appToken.token = element.0
                appToken.expiry = formatter.dateFromString(element.1)
            }
            .map { (token, expiry) -> String? in
                return token
            }
            .logError()

        return newTokenRequest
    }
}

// "Public" interface
extension ProviderType {

    /// Request to fetch a given target. Ensures that valid XApp tokens exist before making request
    func request(token: ArtsyAPI, defaults: NSUserDefaults = NSUserDefaults.standardUserDefaults()) -> Observable<MoyaResponse> {

        if self.providersAuthorization && token.requiresAuthorization {
            return failWith(EidolonError.NotLoggedIn)
        }

        return provider.online
            .ignore(false)  // Wait unti we're online
            .take(1)        // Take 1 to make sure we only invoke the API once.
            .flatMap { _ -> Observable<MoyaResponse> in // Turn the online state into a network request
                let actualRequest = self.provider.request(token)
                return self.XAppTokenRequest(defaults).flatMap { _ in actualRequest }
        }
    }
}

// Static methods
extension Provider {

    private static func newProvider(xAccessToken: String? = nil) -> OnlineProvider<ArtsyAPI> {
        return OnlineProvider(endpointClosure: endpointsClosure(xAccessToken),
            requestClosure: Provider.endpointResolver(),
            stubClosure: APIKeysBasedStubBehaviour,
            plugins: Provider.plugins)
    }

    static func newDefaultProvider() -> Provider {
        return Provider(provider: newProvider())
    }

    static func newAuthorizedProvider(xAccessToken: String) -> AuthorizedProviderType {
        return AuthorizedProvider(provider: newProvider(xAccessToken))
    }

    static func StubbingProvider() -> Provider {
        return Provider(provider: OnlineProvider(endpointClosure: endpointsClosure(), requestClosure: Provider.endpointResolver(), stubClosure: MoyaProvider.ImmediatelyStub, online: just(true)))
    }

    static func endpointsClosure(xAccessToken: String? = nil)(target: ArtsyAPI) -> Endpoint<ArtsyAPI> {
        var endpoint: Endpoint<ArtsyAPI> = Endpoint<ArtsyAPI>(URL: url(target), sampleResponseClosure: {.NetworkResponse(200, target.sampleData)}, method: target.method, parameters: target.parameters)
        if let xAccessToken = xAccessToken {
            endpoint = endpoint.endpointByAddingHTTPHeaderFields(["X-Access-Token": xAccessToken])
        }
        // Sign all non-XApp token requests

        switch target {
        case .XApp:
            return endpoint
        case .XAuth:
            return endpoint

        default:
            return endpoint.endpointByAddingHTTPHeaderFields(["X-Xapp-Token": XAppToken().token ?? ""])
        }
    }

    static func APIKeysBasedStubBehaviour(_: ArtsyAPI) -> Moya.StubBehavior {
        return APIKeys.sharedKeys.stubResponses ? .Immediate : .Never
    }

    static var plugins: [Plugin<ArtsyAPI>] {
        return [NetworkLogger<ArtsyAPI>(whitelist: { (target: ArtsyAPI) -> Bool in
            switch target {
            case .MyBidPosition: return true
            default: return false
            }
            }, blacklist: { target -> Bool in
                switch target {
                case .Ping: return true
                default: return false
                }
        })]
    }

    // (Endpoint<Target>, NSURLRequest -> Void) -> Void
    static func endpointResolver() -> MoyaProvider<ArtsyAPI>.RequestClosure {
        return { (endpoint, closure) in
            let request: NSMutableURLRequest = endpoint.urlRequest.mutableCopy() as! NSMutableURLRequest
            request.HTTPShouldHandleCookies = false
            closure(request)
        }
    }
}
