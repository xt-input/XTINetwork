//
//  XTINetworkManager.swift
//  XTINetwork
//
//  Created by xtinput on 2021/1/6.
//

import Alamofire
import Foundation

public extension Parameters {
    static func += (left: inout Parameters, right: Parameters) {
        right.forEach { key, value in
            left[key] = value
        }
    }
}

public enum XTIHttpScheme: String {
    case http
    case https
}

public class XTINetworkManager {
    fileprivate static var _default: XTINetworkManager?
    /// 默认提供的单例
    public static var `default`: XTINetworkManager {
        if _default == nil {
            _default = XTINetworkManager()
        }
        return _default ?? XTINetworkManager()
    }

    fileprivate let queue: DispatchQueue
    fileprivate var requestsRecord: [String: XTINetworkRequest]

    fileprivate var _host: String?

    /// 主机名，eg: centos8.tcoding.cn, 如果不想分开设置那就用baseUrl eg: http://centos8.tcoding.cn
    public var host: String? {
        get {
            assert(self._host == nil || self._host?.count == 0, "主机名不能为空")
            return self._host
        }
        set {
            self._host = newValue
        }
    }

    /// 链接的scheme，默认为 http
    public var scheme = XTIHttpScheme.http

    fileprivate var _baseUrl: String?
    public var baseUrl: String {
        get {
            if let tempValue = _baseUrl, !tempValue.isEmpty {
                return tempValue
            } else {
                return "\(self.scheme.rawValue)://\(self.host)"
            }
        }
        set {
            assert(newValue.hasPrefix("http"), "baseUrl格式有误")
            self._baseUrl = newValue
        }
    }

    /// 请求超时时间，修改该参数的时候会取消所有的之前的请求
    public var timeoutInterval: TimeInterval {
        didSet {
            self.resetSession()
        }
    }

    /// 最大并发数，修改该参数的时候会取消所有的之前的请求
    public var maximumConnectionsPerHost: Int {
        didSet {
            self.resetSession()
        }
    }

    /// 加密操作
    public var encryptBlock: (_ request: XTINetworkRequest, _ parameters: Parameters) -> Parameters

    /// 解密操作，网络请求完成后的原始的字符串，需要自己解析
    public var decryptBlock: (_ request: XTINetworkRequest, _ value: String) -> String

    /// 构造网络请求头的闭包
    public var httpHeaderBlock: (_ request: XTINetworkRequest, _ header: HTTPHeaders) -> HTTPHeaders

    /// 网络请求结束后，请求状态判断前的操作处理闭包
    public var preOperationCallBack: (_ request: XTINetworkRequest, _ value: Any?, _ error: Error?, _ isCache: Bool) -> (value: Any?, error: Error?)

    /// session
    fileprivate var session: Session

    /// 参数编码格式，表单用URLEncoding.default JSON用JSONEncoding.default
    public var parameterEncoding = URLEncoding.default

    public init() {
        self.httpHeaderBlock = { $1 }
        self.decryptBlock = { $1 }
        self.encryptBlock = { $1 }
        self.preOperationCallBack = { _, value, error, _ in (value, error) }
        self.session = Session()
        self.maximumConnectionsPerHost = 10
        self.timeoutInterval = 30.0
        self.queue = DispatchQueue(label: "cn.tcoding.XTINetwork.manager.\(UUID().uuidString)")
        self.requestsRecord = [String: XTINetworkRequest]()
    }

    fileprivate func resetSession() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = self.timeoutInterval
        configuration.httpMaximumConnectionsPerHost = self.maximumConnectionsPerHost
        self.session.cancelAllRequests()
        self.session = Session(configuration: configuration)
    }
}

fileprivate extension XTINetworkRequest {
    fileprivate var identifier: String {
        afRequest?.id.uuidString ?? ""
    }
}

public extension XTINetworkManager {
    /// 构造网络请求
    fileprivate func buildCustomUrlRequest(_ request: XTINetworkRequest) -> DataRequest? {
        var afRequest: DataRequest?

        afRequest = self.session.request(request.requestUrl, method: request.method, parameters: request.requestParameters(), encoding: request.parameterEncoding, headers: request.requestHeaders())

        return afRequest
    }

    fileprivate func success(_ request: XTINetworkRequest, value: String, isCache: Bool) {
        var tempValue = request.decrypt(value)
        let handleValue = request.preOperation(tempValue, error: nil, isCache: isCache).0
        if let successBlock = request.successBlock {
            successBlock(handleValue, isCache)
        }
        if let completeBlock = request.completedBlock {
            completeBlock(handleValue, nil, isCache)
        }
    }

    /// 处理请求结果
    fileprivate func handleRequestResult(_ request: XTINetworkRequest, result: AFDataResponse<String>) {
        var tempRequest: XTINetworkRequest?
        self.queue.sync { [weak self] in
            tempRequest = self?.requestsRecord.removeValue(forKey: request.identifier)
        }
        guard let handleRequest = tempRequest else {
            return
        }

        switch result.result {
        case let .success(resultValue):
            // 在这里可以把结果缓存
            handleRequest.saveCache(resultValue)
            self.success(handleRequest, value: resultValue, isCache: false)

        case let .failure(error):
            let handleError = handleRequest.preOperation(nil, error: error, isCache: false).1
            if let failureBlock = request.failureBlock {
                failureBlock(handleError)
            }
            if let completeBlock = request.completedBlock {
                completeBlock(nil, handleError, false)
            }
        }
        handleRequest.didCompletion(false)
        handleRequest.clearCompletionBlock()
    }

    public func addRequest(_ request: XTINetworkRequest) {
        guard let sendRequest = buildCustomUrlRequest(request) else {
            return
        }
        request.afRequest = sendRequest
        self.queue.sync { [weak self] in
            self?.requestsRecord[request.identifier] = request
        }
        request.willStart()
        // 在这里读取缓存
        if let resultValue = request.cache() {
            self.success(request, value: resultValue, isCache: true)
        }
        sendRequest.validate(statusCode: 200 ..< 300).responseString(encoding: request.resultEncoding) { [weak self] result in
            self?.handleRequestResult(request, result: result)
        }
    }

    public func cancelRequest(_ request: XTINetworkRequest) {
        var tempRequest: XTINetworkRequest?
        self.queue.sync { [weak self] in
            tempRequest = self?.requestsRecord.removeValue(forKey: request.identifier)
        }
        tempRequest?.afRequest?.cancel()
        tempRequest?.didCompletion(true)
    }
}

/// 通过单例发起请求
public extension XTINetworkManager {
    @discardableResult public static func send(_ method: HTTPMethod = .post, url: String, parameters: Parameters = [:], success successBlock: XTIRequestSuccessCallBack? = nil, failure failureBlock: XTIRequestFailureCallBack? = nil, completed completedBlock: XTIRequestCompleteCallBack? = nil) -> XTINetworkRequest {
        let request = XTINetworkRequest(self.default)
        request.requestUrl = url
        request.method = method
        request.parameters = parameters
        request.successBlock = successBlock
        request.failureBlock = failureBlock
        request.completedBlock = completedBlock
        DispatchQueue.main.async {
            self.default.addRequest(request)
        }
        return request
    }

    @discardableResult public static func send(_ method: HTTPMethod = .post, serverName: String, parameters: Parameters = [:], success successBlock: XTIRequestSuccessCallBack? = nil, failure failureBlock: XTIRequestFailureCallBack? = nil, completed completedBlock: XTIRequestCompleteCallBack? = nil) -> XTINetworkRequest {
        let request = XTINetworkRequest(self.default)
        request.serverName = serverName
        request.method = method
        request.parameters = parameters
        request.successBlock = successBlock
        request.failureBlock = failureBlock
        request.completedBlock = completedBlock
        DispatchQueue.main.async {
            self.default.addRequest(request)
        }
        return request
    }
}
