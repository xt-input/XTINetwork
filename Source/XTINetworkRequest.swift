//
//  XTINetworkRequest.swift
//  XTINetwork
//
//  Created by xtinput on 2021/1/6.
//

import Alamofire
import Foundation

import typealias CommonCrypto.CC_LONG
import func CommonCrypto.CC_MD5
import var CommonCrypto.CC_MD5_DIGEST_LENGTH

/// 网络请求成功的回调
public typealias XTIRequestSuccessCallBack = (Any?, Bool) -> Void
/// 网络请求失败的回调
public typealias XTIRequestFailureCallBack = (Error?) -> Void
/// 网络请求完成的回调
public typealias XTIRequestCompleteCallBack = (Any?, Error?, Bool) -> Void

/// 文件上传下载进度的回调
public typealias XTIProgressCallBack = (Progress) -> Void

open class XTINetworkRequest {
    fileprivate var _manager: XTINetworkManager
    public var manager: XTINetworkManager {
        return self._manager
    }

    public var method = HTTPMethod.post
    public var afRequest: Request?
    fileprivate var _parameterEncoding: ParameterEncoding?

    // 请求结果字符串编码格式
    public var resultEncoding: String.Encoding? = .utf8

    public var parameterEncoding: ParameterEncoding {
        get {
            if self._parameterEncoding != nil {
                return self._parameterEncoding ?? URLEncoding.default
            }
            return self.manager.parameterEncoding
        }
        set {
            self._parameterEncoding = newValue
        }
    }

    /// 请求方法名
    public var serverName: String?

    /// 完整的请求链接为 "baseUrl/serverName"
    public var baseUrl: String {
        self.manager.baseUrl
    }

    fileprivate var _requestUrl: String?
    /// 完整的请求链接
    public var requestUrl: String {
        get {
            if let tempUrl = _requestUrl, tempUrl.count > 0 {
                return tempUrl
            } else {
                var tempBaseUrl = self.baseUrl
                if tempBaseUrl.hasSuffix("/") { tempBaseUrl.removeLast() }
                var tempServerName = self.serverName ?? ""
                if tempServerName.hasPrefix("/") { tempServerName.removeFirst() }
                return "\(tempBaseUrl)/\(tempServerName)"
            }
        }
        set {
            self._requestUrl = newValue
        }
    }

    /// 请求头
    public var headers: HTTPHeaders = [:]

    /// 请求体
    public var parameters: Parameters = [:]
    /// 请求成功的回调
    public var successBlock: XTIRequestSuccessCallBack?
    /// 请求失败的回调
    public var failureBlock: XTIRequestFailureCallBack?
    /// 请求完成的回调
    public var completedBlock: XTIRequestCompleteCallBack?

    /// 接口缓存时间，默认为7天，，单位（秒）；如果大于XTINetworkCacheManager配置的时间则以XTINetworkCacheManager为准，仅get方法进行缓存
    public var cacheTime: TimeInterval

    /// 需要忽略的参数名
    public var cacheIgnoreParameters: [String] = []
    public var useCache: Bool = true

    /// cacheResult
    fileprivate var cacheResult: String?
    fileprivate var cacheCreateTime: Date?

    public init(_ manager: XTINetworkManager? = nil) {
        self._manager = manager ?? XTINetworkManager.default
        self.cacheTime = 7 * 24 * 60 * 60
    }

    deinit {
        #if DEBUG
            print("deinit \(Self.self)")
        #endif
    }
}

public extension XTINetworkRequest {
    open func requestHeaders() -> HTTPHeaders {
        return self.manager.httpHeaderBlock(self, self.headers)
    }

    /// 如果要触发加密，那么子类一定要调用super.requestParameters()
    open func requestParameters() -> Parameters {
        return self.encrypt(self.parameters)
    }

    open func encrypt(_ parameters: Parameters) -> Parameters {
        return self.manager.encryptBlock(self, parameters)
    }

    open func decrypt(_ value: String) -> String {
        return self.manager.decryptBlock(self, value)
    }

    open func preOperation(_ value: Any?, error: Error?, isCache: Bool) -> (Any?, Error?) {
        return self.manager.preOperationCallBack(self, value, error, isCache)
    }
}

public extension XTINetworkRequest {
    /// 即将发起请求
    open func willStart() {
    }

    /// 发起请求
    open func start(_ successBlock: XTIRequestSuccessCallBack? = nil, failure failureBlock: XTIRequestFailureCallBack? = nil, completed completedBlock: XTIRequestCompleteCallBack? = nil) {
        self.successBlock = successBlock
        self.failureBlock = failureBlock
        self.completedBlock = completedBlock
        self.manager.addRequest(self)
    }

    /// 取消请求
    open func cancel() {
        self.clearCompletionBlock()
        self.manager.cancelRequest(self)
    }

    /// 已经结束请求，是否是取消
    open func didCompletion(_ isCancel: Bool) {
    }

    open func clearCompletionBlock() {
        self.successBlock = nil
        self.failureBlock = nil
        self.completedBlock = nil
    }
}

/// cache路径相关
fileprivate extension XTINetworkRequest {
    func md5(_ string: String) -> String {
        let length = Int(CC_MD5_DIGEST_LENGTH)
        let messageData = string.data(using: .utf8)!
        var digestData = Data(count: length)

        _ = digestData.withUnsafeMutableBytes { digestBytes -> UInt8 in
            messageData.withUnsafeBytes { messageBytes -> UInt8 in
                if let messageBytesBaseAddress = messageBytes.baseAddress, let digestBytesBlindMemory = digestBytes.bindMemory(to: UInt8.self).baseAddress {
                    let messageLength = CC_LONG(messageData.count)
                    CC_MD5(messageBytesBaseAddress, messageLength, digestBytesBlindMemory)
                }
                return 0
            }
        }
        return digestData.map { String(format: "%02hhx", $0) }.joined().uppercased()
    }

    var cacheFileName: String {
        self.parameters.sorted { (parameter1, parameter2) -> Bool in
            parameter1.key.uppercased() > parameter2.key.uppercased()
        }
        return self.md5(String(format: "%@%@%@", self.method.rawValue, self.requestUrl, self.parameters)) + ".request"
    }
}

public extension XTINetworkRequest {
    /// 针对多用户的接口缓存作用，可以用用户名等字段来分辨
    /// - Returns: 文件夹名
    open func cacheFolder() -> String {
        return "\(self.self)"
    }

    /// 请求缓存的相对路径
    open var cacheFliePath: String {
        "\(self.cacheFolder())/\(self.cacheFileName)"
    }

    public func saveCache(_ value: String) {
        if !self.useCache {
            return
        }
        self.cacheCreateTime = Date()
        self.cacheResult = value
        // 将缓存写入文件
        XTINetworkCacheManager.addCache(self.cacheFliePath, value: value)
    }

    public func cache() -> String? {
        if !self.useCache {
            return nil
        }
        let nowTime = Date()

        if self.cacheResult != nil {
            if nowTime.timeIntervalSince1970 - self.cacheTime > (self.cacheCreateTime?.timeIntervalSince1970 ?? 0) {
                return self.cacheResult
            }
        } else {
            // 从文件读取缓存
            return XTINetworkCacheManager.cacheString(self.cacheFliePath)
        }
        return nil
    }
}

fileprivate class XTINetworkCache {
    let group: String
    let filePath: String
    let infoFilePath: String
    let createTime: Date

    init(_ filePath: String) {
        self.createTime = Date()

        let list = filePath.components(separatedBy: "/")
        var group = "default"
        if list.count >= 2 {
            group = list.first ?? group
        }
        self.group = group

        self.infoFilePath = "info/\(group)/\(filePath)"
        self.filePath = "\(group)/\(filePath)"
    }
}

/// 该类获取和添加缓存的方法都会堵塞当前线程
public class XTINetworkCacheManager {
    fileprivate static let queue: DispatchQueue = DispatchQueue(label: "cn.tcoding.XTINetwork.cacheManager")

    /// 缓存过期时间，默认是15天，单位（秒）
    fileprivate static var expiredTime: TimeInterval = 15 * 24 * 60 * 60

    public static func removeAll() {
        try? FileManager.default.removeItem(atPath: cacheBasePath)
    }

    public static func remove(_ group: String = "default") {
        try? FileManager.default.removeItem(atPath: cacheBasePath + "/\(group)")
        try? FileManager.default.removeItem(atPath: cacheBasePath + "/info/\(group)")
    }
}

fileprivate extension XTINetworkCacheManager {
    static func cache(_ filePath: String) -> Data? {
        var cacheInfo: XTINetworkCache = self.getCacheInfo(filePath)
        if let tempCacheInfo = NSKeyedUnarchiver.unarchiveObject(withFile: "\(cacheBasePath)/\(cacheInfo.infoFilePath)") as? XTINetworkCache {
            let nowTime = Date()
            if nowTime.timeIntervalSince1970 - tempCacheInfo.createTime.timeIntervalSince1970 <= self.expiredTime {
                var data: Data?
                self.queue.sync {
                    try? data = Data(contentsOf: URL(fileURLWithPath: "\(cacheBasePath)/\(tempCacheInfo.filePath)"))
                }
                return data
            }
        }
        return nil
    }

    static func cacheString(_ filePath: String) -> String? {
        if let tempData = cache(filePath) {
            String(data: tempData, encoding: .utf8)
        }
        return nil
    }

    @discardableResult static func addCache(_ filePath: String, value: String, completedBlock: ((_ success: Bool) -> Void)? = nil) {
        self.addCache(filePath, data: value.data(using: .utf8) ?? Data())
    }

    @discardableResult static func addCache(_ filePath: String, data: Data, completedBlock: ((_ success: Bool) -> Void)? = nil) {
        guard !self.cacheBasePath.isEmpty && !filePath.isEmpty else {
            if completedBlock != nil {
                completedBlock?(false)
            }
            return
        }
        let cacheInfo = self.getCacheInfo(filePath)
        self.queue.async {
            var flag = true
            do {
                try data.write(to: URL(fileURLWithPath: "\(cacheBasePath)/\(cacheInfo.filePath)"))
            } catch {
                flag = false
            }
            if flag {
                flag = NSKeyedArchiver.archiveRootObject(cacheInfo, toFile: "\(cacheBasePath)/\(cacheInfo.infoFilePath)")
                if completedBlock != nil {
                    completedBlock?(flag)
                }
            }
        }
    }

    static func getCacheInfo(_ filePath: String) -> XTINetworkCache {
        return XTINetworkCache(filePath)
    }

    static func createBaseDirectory(_ atPath: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: atPath), withIntermediateDirectories: true, attributes: nil)
        } catch {
            return false
        }
        return true
    }

    static var cacheBasePath: String {
        let path = (NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first ?? "").appending("/cn.tcoding.Cache.Request")
        var isDirectory = ObjCBool(false)
        var needCreateDirectory = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            needCreateDirectory = !isDirectory.boolValue
        } else {
            needCreateDirectory = true
        }
        if !needCreateDirectory || (needCreateDirectory && createBaseDirectory(path)) {
            return path
        }

        return ""
    }
}
