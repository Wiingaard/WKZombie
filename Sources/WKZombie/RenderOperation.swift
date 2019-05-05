//
// RenderOperation.swift
//
// Copyright (c) 2015 Mathias Koehnke (http://www.mathiaskoehnke.de)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import WebKit

//========================================
// MARK: RenderOperation
//========================================

typealias RequestBlock = (_ operation: RenderOperation) -> Void

internal class RenderOperation : Operation {
    
    fileprivate(set) weak var webView : WKWebView?
    fileprivate var timeout : Timer?
    fileprivate let timeoutInSeconds : TimeInterval
    fileprivate var stopRunLoop : Bool = false
    
    var loadMediaContent : Bool = true
    var showNetworkActivity : Bool = true
    var requestBlock : RequestBlock?
    var authenticationBlock : AuthenticationHandler?
    var postAction: PostAction = .none
    
    internal fileprivate(set) var result : Data?
    internal fileprivate(set) var response : URLResponse?
    internal fileprivate(set) var error : Error?
    
    fileprivate var _executing: Bool = false
    override var isExecuting: Bool {
        get {
            return _executing
        }
        set {
            if _executing != newValue {
                willChangeValue(forKey: "isExecuting")
                _executing = newValue
                didChangeValue(forKey: "isExecuting")
            }
        }
    }
    
    fileprivate var _finished: Bool = false;
    override var isFinished: Bool {
        get {
            return _finished
        }
        set {
            if _finished != newValue {
                willChangeValue(forKey: "isFinished")
                _finished = newValue
                didChangeValue(forKey: "isFinished")
            }
        }
    }
    
    init(webView: WKWebView, timeoutInSeconds : TimeInterval = 30.0) {
        self.timeoutInSeconds = timeoutInSeconds
        super.init()
        self.webView = webView
    }
    
    override func start() {
        if self.isCancelled {
            return
        } else {
            Logger.log("\(name ?? String())")
            Logger.log("[", lineBreak: false)
            isExecuting = true
            startTimeout()
            
            // Wait for WKWebView to finish loading before starting the operation.
            wait {
                guard let webView = webView else {
                    return false
                }
                var isLoading = false
                dispatch_sync_on_main_thread {
                    isLoading = webView.isLoading
                }
                return !isLoading
            }
            
            setupReferences()
            requestBlock?(self)
            
            // Loading
            wait { [unowned self] in self.stopRunLoop }
        }
    }
    
    func wait(_ condition: () -> Bool) {
        let updateInterval : TimeInterval = 0.1
        var loopUntil = Date(timeIntervalSinceNow: updateInterval)
        while condition() == false && RunLoop.current.run(mode: RunLoopMode.defaultRunLoopMode, before: loopUntil) {
            loopUntil = Date(timeIntervalSinceNow: updateInterval)
            Logger.log(".", lineBreak: false)
        }
    }
    
    func completeRendering(_ webView: WKWebView?, result: Data? = nil, error: Error? = nil) {
        stopTimeout()
        
        if isExecuting == true && isFinished == false {
            self.result = result ?? self.result
            self.error = error ?? self.error

            cleanupReferences()
            
            isExecuting = false
            isFinished = true
            
            Logger.log("]\n")
        }
    }
    
    override func cancel() {
        Logger.log("Cancelling Rendering - \(String(describing: name))")
        super.cancel()
        stopTimeout()
        cleanupReferences()
        isExecuting = false
        isFinished = true
    }
    
    // MARK: Helper Methods
    
    fileprivate func startTimeout() {
        stopRunLoop = false
        timeout = Timer(timeInterval: timeoutInSeconds, target: self, selector: #selector(RenderOperation.cancel), userInfo: nil, repeats: false)
        RunLoop.current.add(timeout!, forMode: RunLoopMode.defaultRunLoopMode)
    }
    
    fileprivate func stopTimeout() {
        timeout?.invalidate()
        timeout = nil
        stopRunLoop = true
    }
    
    fileprivate func setupReferences() {
        dispatch_sync_on_main_thread {
            webView?.configuration.userContentController.add(self, name: "doneLoading")
            webView?.navigationDelegate = self
        }
    }
    
    fileprivate func cleanupReferences() {
        dispatch_sync_on_main_thread {
            webView?.navigationDelegate = nil
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "doneLoading")
            webView = nil
            authenticationBlock = nil
        }
    }
}

//========================================
// MARK: WKScriptMessageHandler
//========================================

extension RenderOperation : WKScriptMessageHandler {
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        //None of the content loaded after this point is necessary (images, videos, etc.)
        if let webView = message.webView {
            if message.name == "doneLoading" && loadMediaContent == false {
                if let url = webView.url , response == nil {
                    response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                }
                webView.stopLoading()
                self.webView(webView, didFinish: nil)
            }
        }
    }
}

//========================================
// MARK: WKNavigationDelegate
//========================================

extension RenderOperation : WKNavigationDelegate {
    
    private func setNetworkActivityIndicatorVisible(visible : Bool) {
        #if os(iOS)
        if showNetworkActivity { UIApplication.shared.isNetworkActivityIndicatorVisible = visible }
        #endif
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setNetworkActivityIndicatorVisible(visible: showNetworkActivity)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        response = navigationResponse.response
        saveCookies(from: navigationResponse)
        decisionHandler(.allow)
    }
    
    /// Custom function from fork. Saving cookies from navigation response in shared cookies, this allows Alamofire (URLSession) to pass server auth.
    private func saveCookies(from navigationResponse: WKNavigationResponse) {
        let saveCookiesGlobally: ([HTTPCookie]) -> () = {
            $0.forEach(HTTPCookieStorage.shared.setCookie)
        }
        
        if #available(iOS 11.0, *) {
            self.webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies(saveCookiesGlobally)
        } else {
            guard let httpResponse = navigationResponse.response as? HTTPURLResponse, let url = httpResponse.url else { return }
            
            let allHeaders = httpResponse.allHeaderFields.reduce([String : String](), { (result, next) -> [String : String] in
                guard let stringKey = next.key as? String, let stringValue = next.value as? String else { return result }
                var buffer = result
                buffer[stringKey] = stringValue
                return buffer
            })
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: allHeaders, for: url)
            saveCookiesGlobally(cookies)
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        setNetworkActivityIndicatorVisible(visible: false)
        if let response = response as? HTTPURLResponse, let _ = completionBlock {
            let successRange = 200..<300
            if !successRange.contains(response.statusCode) {
                self.error = error
                self.completeRendering(webView)
            }
        }
        Logger.log(error.localizedDescription)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setNetworkActivityIndicatorVisible(visible: false)
        switch postAction {
        case .wait, .validate: handlePostAction(postAction, webView: webView)
        case .none: finishedLoading(webView)
        }
    }
    
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let authenticationBlock = authenticationBlock {
            let authenticationResult = authenticationBlock(challenge)
            completionHandler(authenticationResult.0, authenticationResult.1)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        self.completeRendering(webView)
        Logger.log(error.localizedDescription)
    }
}

//========================================
// MARK: Validation
//========================================

extension RenderOperation {
        
    func finishedLoading(_ webView: WKWebView) {
        webView.evaluateJavaScript("\(Renderer.scrapingCommand);") { [weak self] result, error in
            self?.result = (result as? String)?.data(using: String.Encoding.utf8)
            self?.completeRendering(webView)
        }
    }
    
    func validate(_ condition: String, webView: WKWebView) {
        if isFinished == false && isCancelled == false {
            webView.evaluateJavaScript(condition) { [weak self] result, error in
                if let result = result as? Bool , result == true {
                    self?.finishedLoading(webView)
                } else {
                    delay(0.5, completion: {
                        self?.validate(condition, webView: webView)
                    })
                }
            }
        }
    }
    
    func waitAndFinish(_ time: TimeInterval, webView: WKWebView) {
        delay(time) {
            self.finishedLoading(webView)
        }
    }
    
    func handlePostAction(_ postAction: PostAction, webView: WKWebView) {
        switch postAction {
        case .validate(let script): validate(script, webView: webView)
        case .wait(let time): waitAndFinish(time, webView: webView)
        default: Logger.log("Something went wrong!")
        }
        self.postAction = .none
    }
    
}

