//
// AbstractChatViewControllerWithSharing.swift
//
// BeagleIM
// Copyright (C) 2018 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License,
// or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see http://www.gnu.org/licenses/.
//

import AppKit
import TigaseSwift

class AbstractChatViewControllerWithSharing: AbstractChatViewController, URLSessionTaskDelegate, NSDraggingDestination {

    @IBOutlet var sharingProgressBar: NSProgressIndicator!;
    @IBOutlet var sharingButton: NSButton!;
    
    var isSharingAvailable: Bool {
        guard let uploadModule: HttpFileUploadModule = XmppService.instance.getClient(for: account!)?.modulesManager.getModule(HttpFileUploadModule.ID) else {
            return false;
        }
        return uploadModule.isAvailable;
    }
    
    override func viewDidLoad() {
        super.viewDidLoad();
        NotificationCenter.default.addObserver(self, selector: #selector(sharingSupportChanged), name: HttpFileUploadEventHandler.UPLOAD_SUPPORT_CHANGED, object: nil);
        messageField.dragHandler = self;
    }
    
    override func viewWillAppear() {
        super.viewWillAppear();
        self.sharingButton.isEnabled = self.isSharingAvailable;
    }
    
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if self.sharingButton.isEnabled, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], urls.count == 1, let url = urls.first, url.isFileURL {
            self.uploadFileToHttpServer(url: url, onSuccess: { (uploadedUrl) in
                DispatchQueue.main.async {
                    _ = self.sendMessage(url: uploadedUrl.absoluteString);
                }
            });
            return true;
        }
        return false;
    }
    
    @objc func sharingSupportChanged(_ notification: Notification) {
        guard let account = notification.object as? BareJID else {
            return;
        }
        guard self.account != nil && self.account! == account else {
            return;
        }
        DispatchQueue.main.async {
            self.sharingButton.isEnabled = self.isSharingAvailable;
        }
    }
    
    @IBAction func attachFile(_ sender: NSButton) {
        self.selectFile { (url) in
            self.uploadFileToHttpServer(url: url, onSuccess: { (uploadedUrl) in
                DispatchQueue.main.async {
                    _ = self.sendMessage(url: uploadedUrl.absoluteString);
                }
            });
        }
    }
    
    func selectFile(completionHandler: @escaping (URL)->Void) {
        let openFile = NSOpenPanel();
        openFile.worksWhenModal = true;
        openFile.prompt = "Select files to share";
        openFile.canChooseDirectories = false;
        openFile.canChooseFiles = true;
        openFile.canSelectHiddenExtension = true;
        openFile.canCreateDirectories = false;
        openFile.allowsMultipleSelection = false;
        openFile.resolvesAliases = true;

        openFile.begin { (response) in
            print("got response", response.rawValue);
            if response == .OK, let url = openFile.url {
                completionHandler(url);
            }
        }
    }
    
    fileprivate func uploadFileToHttpServer(url: URL, onSuccess: @escaping (URL)->Void) {
        uploadFileToHttpServer(url: url) { (uploadedUrl, errorCondition, errorMessage) in
            guard errorCondition == nil else {
                let alert = NSAlert();
                alert.icon = NSImage(named: NSImage.cautionName);
                alert.messageText = "Upload error";
                alert.informativeText = errorMessage ?? "Received an error: \(errorCondition!.rawValue)";
                alert.addButton(withTitle: "OK");
                alert.beginSheetModal(for: self.view.window!, completionHandler: nil);
                return;
            }
            DispatchQueue.main.async {
                onSuccess(uploadedUrl!);
            }
        }
    }
    
    func uploadFileToHttpServer(url: URL, completionHandler: @escaping (URL?, ErrorCondition?, String?)->Void) {
        print("selected file:", url);
        guard let uploadModule: HttpFileUploadModule = XmppService.instance.getClient(for: account)?.modulesManager.getModule(HttpFileUploadModule.ID) else {
            completionHandler(nil, ErrorCondition.feature_not_implemented, "HttpFileUploadModule not enabled!");
            return;
        }
        guard let component = uploadModule.availableComponents.first else {
            print("could not found any HTTP upload component!");
            completionHandler(nil, ErrorCondition.feature_not_implemented, "Server does not support XEP-0363: HTTP File Upload");
            return;
        }

        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path);
        let filesize = attributes[FileAttributeKey.size] as! UInt64;
        
        let contentType = guessContentType(of: url);
        uploadModule.requestUploadSlot(componentJid: component.jid, filename: url.lastPathComponent, size: Int(filesize), contentType: contentType, onSuccess: { (slot) in
            DispatchQueue.main.async {
                self.sharingProgressBar.isHidden = false;
            }
            var request = URLRequest(url: slot.putUri);
            slot.putHeaders.forEach({ (k,v) in
                request.addValue(v, forHTTPHeaderField: k);
            });
            if contentType != nil {
                request.addValue(contentType!, forHTTPHeaderField: "Content-Type")
            }
            request.httpMethod = "PUT";
            request.httpBody = try! Data(contentsOf: url);
                
            let session = URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: OperationQueue.main);
            session.dataTask(with: request, completionHandler: { (data, response, error) in
                let code = ((response as? HTTPURLResponse)?.statusCode ?? 500);
                guard error == nil && code == 201 else {
                    print("received HTTP error response", error as Any, code);
                    self.sharingProgressBar.isHidden = true;
                    completionHandler(nil, ErrorCondition.internal_server_error, "Could not upload data to the HTTP server" + (error == nil ? "" : (":\n" + error!.localizedDescription)));
                    return;
                }
                    
                print("file uploaded at:", slot.getUri);
                self.sharingProgressBar.isHidden = true;
                completionHandler(slot.getUri, nil, nil);
            }).resume();
        }, onError: { (errorCondition, errorText) in
            print("failedd to allocate slot:", errorCondition as Any, errorText as Any);
            completionHandler(nil, errorCondition, errorText);
        })
    }

    func guessContentType(of url: URL) -> String? {
        guard let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, url.pathExtension as CFString, nil)?.takeRetainedValue() else {
            return nil;
        }
        
        if UTTypeConformsTo(uti, kUTTypeImage) {
            if UTTypeConformsTo(uti, kUTTypePNG) {
                return "image/png";
            }
            if UTTypeConformsTo(uti, kUTTypeJPEG) || UTTypeConformsTo(uti, kUTTypeJPEG2000) {
                return "image/jpeg";
            }
            if UTTypeConformsTo(uti, kUTTypeGIF) {
                return "image/gif";
            }
        }
        if UTTypeConformsTo(uti, kUTTypeMovie) || UTTypeConformsTo(uti, kUTTypeVideo) {
            if UTTypeConformsTo(uti, kUTTypeMPEG2Video) {
                return "video/mpeg";
            }
            if UTTypeConformsTo(uti, kUTTypeMPEG4) {
                return "video/mp4";
            }
            if UTTypeConformsTo(uti, kUTTypeAVIMovie) {
                return "video/x-msvideo";
            }
        }
        
        return nil;
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            var trustResult: SecTrustResultType = .invalid;
            if SecTrustGetTrustResult(trust, &trustResult) == noErr {
                if trustResult == .proceed || trustResult == .unspecified {
                     let credential = URLCredential(trust: trust);
                    completionHandler(URLSession.AuthChallengeDisposition.performDefaultHandling, credential);
                    return;
                }
            }

            let info = SslCertificateInfo(trust: trust);
            DispatchQueue.main.async {
                let alert = NSAlert();
                alert.icon = NSImage(named: NSImage.cautionName);
                alert.messageText = "Invalid SSL certificate";
                alert.informativeText = "HTTP File Upload server presented invalid SSL certificate for \(challenge.protectionSpace.host).\nReceived certificate \(info.details.name) (\(info.details.fingerprintSha1))" + (info.issuer == nil ? " is self-signed!" : " issued by \(info.issuer!.name).") + "\n\nWould you like to connect to the server anyway?";
                alert.addButton(withTitle: "Yes");
                alert.addButton(withTitle: "No");
                alert.beginSheetModal(for: self.view.window!, completionHandler: { (response) in
                    switch response {
                    case .alertFirstButtonReturn:
                        let credential = URLCredential(trust: trust);
                        completionHandler(URLSession.AuthChallengeDisposition.useCredential, credential);
                    default:
                        completionHandler(URLSession.AuthChallengeDisposition.performDefaultHandling, nil);
                    }
                })
            }
        } else {
            completionHandler(URLSession.AuthChallengeDisposition.performDefaultHandling, nil);
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        DispatchQueue.main.async {
            self.sharingProgressBar.minValue = 0;
            self.sharingProgressBar.maxValue = 1;
            self.sharingProgressBar.doubleValue = Double(totalBytesSent) / Double(totalBytesExpectedToSend);
            if self.sharingProgressBar.doubleValue == 1 {
                self.sharingProgressBar.isHidden = true;
                self.sharingProgressBar.doubleValue = 0;
            } else {
                self.sharingProgressBar.isHidden = false;
            }
        }
    }
}
