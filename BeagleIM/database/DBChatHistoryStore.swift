//
// DBChatHistoryStore.swift
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

import Foundation
import TigaseSwift

class DBChatHistoryStore {
    
    static let MESSAGE_NEW = Notification.Name("messageAdded");
    static let MESSAGES_MARKED_AS_READ = Notification.Name("messagesMarkedAsRead");
    static let MESSAGE_UPDATED = Notification.Name("messageUpdated");
    static var instance: DBChatHistoryStore = DBChatHistoryStore.init();

    fileprivate let appendMessageStmt: DBStatement = try! DBConnection.main.prepareStatement("INSERT INTO chat_history (account, jid, timestamp, item_type, data, stanza_id, state, author_nickname, author_jid) VALUES (:account, :jid, :timestamp, :item_type, :data, :stanza_id, :state, :author_nickname, :author_jid)");
    fileprivate let checkItemAlreadyAddedStmt: DBStatement = try! DBConnection.main.prepareStatement("SELECT count(id) FROM chat_history WHERE account = :account AND jid = :jid AND timestamp BETWEEN :ts_from AND :ts_to AND item_type = :item_type AND data = :data AND (:stanza_id IS NULL OR (stanza_id IS NOT NULL AND stanza_id = :stanza_id)) AND (state % 2 == :direction) AND (:author_nickname is null OR author_nickname = :author_nickname)");
    fileprivate let markAsReadStmt: DBStatement = try! DBConnection.main.prepareStatement("UPDATE chat_history SET state = case state when \(MessageState.incoming_error_unread.rawValue) then \(MessageState.incoming_error.rawValue) when \(MessageState.outgoing_error_unread.rawValue) then \(MessageState.outgoing_error.rawValue) else \(MessageState.incoming.rawValue) end WHERE account = :account AND jid = :jid AND state in (\(MessageState.incoming_unread.rawValue), \(MessageState.incoming_error_unread.rawValue), \(MessageState.outgoing_error_unread.rawValue))");
    fileprivate let updateItemStateStmt: DBStatement = try! DBConnection.main.prepareStatement("UPDATE chat_history SET state = :newState WHERE id = :id AND (:oldState IS NULL OR state = :oldState)");
    fileprivate let updateItemStmt: DBStatement = try! DBConnection.main.prepareStatement("UPDATE chat_history SET preview = coalesce(:preview, preview) WHERE id = :id");
    fileprivate let markAsErrorStmt: DBStatement = try! DBConnection.main.prepareStatement("UPDATE chat_history SET state = :state, error = :error WHERE id = :id");
    
    fileprivate let getItemIdByStanzaId: DBStatement = try! DBConnection.main.prepareStatement("SELECT id FROM chat_history WHERE account = :account AND jid = :jid AND stanza_id = :stanza_id ORDER BY timestamp DESC");
    fileprivate let getChatMessagesStmt: DBStatement = try! DBConnection.main.prepareStatement("SELECT id, author_nickname, author_jid, timestamp, item_type, data, state, preview FROM chat_history WHERE account = :account AND jid = :jid ORDER BY timestamp DESC LIMIT :limit OFFSET :offset");
    fileprivate let getChatMessageWithIdStmt: DBStatement = try! DBConnection.main.prepareStatement("SELECT id, author_nickname, author_jid, timestamp, item_type, data, state, preview FROM chat_history WHERE id = :id");

    fileprivate let getChatMessagePosition: DBStatement = try! DBConnection.main.prepareStatement("SELECT count(id) FROM chat_history WHERE account = :account AND jid = :jid AND id <> :msgId AND timestamp > (SELECT timestamp FROM chat_history WHERE id = :msgId)")
    fileprivate let removeChatHistoryStmt: DBStatement = try! DBConnection.main.prepareStatement("DELETE FROM chat_history WHERE account = :account AND (:jid IS NULL OR jid = :jid)");
    
    fileprivate let dispatcher: QueueDispatcher;
    
    public init() {
        dispatcher = QueueDispatcher(label: "chat_history_store");
    }
    
    open func process(chatState: ChatState, for account: BareJID, with jid: BareJID) {
        dispatcher.async {
            DBChatStore.instance.process(chatState: chatState, for: account, with: jid);
        }
    }
    
    open func appendItem(for account: BareJID, with jid: BareJID, state: MessageState, authorNickname: String? = nil, authorJid: BareJID? = nil, type: ItemType = .message, timestamp: Date, stanzaId: String?, data: String, chatState: ChatState? = nil, errorCondition: ErrorCondition? = nil, errorMessage: String? = nil, completionHandler: ((Int) -> Void)?) {
        dispatcher.async {
            guard !state.isError || stanzaId == nil || !self.processOutgoingError(for: account, with: jid, stanzaId: stanzaId!, errorCondition: errorCondition, errorMessage: errorMessage) else {
                return;
            }
            
            guard !self.checkItemAlreadyAdded(for: account, with: jid, authorNickname: authorNickname, type: type, timestamp: timestamp, direction: state.direction, stanzaId: stanzaId, data: data) else {
                if chatState != nil {
                    DBChatStore.instance.process(chatState: chatState!, for: account, with: jid);
                }
                return;
            }
            
            let params: [String:Any?] = ["account": account, "jid": jid, "timestamp": timestamp, "data": data, "item_type": type.rawValue, "state": state.rawValue, "stanza_id": stanzaId, "author_nickname": authorNickname, "author_jid": authorJid];
            guard let msgId = try! self.appendMessageStmt.insert(params) else {
                return;
            }
            completionHandler?(msgId);
            
            let item = ChatMessage(id: msgId, timestamp: timestamp, account: account, jid: jid, state: state, message: data, authorNickname: authorNickname, authorJid: authorJid);
            NotificationCenter.default.post(name: DBChatHistoryStore.MESSAGE_NEW, object: item);
            DBChatStore.instance.newMessage(for: account, with: jid, timestamp: timestamp, message: data, state: state, remoteChatState: state.direction == .incoming ? chatState : nil);
        }
    }
    
    open func removeHistory(for account: BareJID, with jid: BareJID?) {
        dispatcher.async {
            let params: [String: Any?] = ["account": account, "jid": jid];
            _ = try! self.removeChatHistoryStmt.update(params);
        }
    }
    
    fileprivate func processOutgoingError(for account: BareJID, with jid: BareJID, stanzaId: String, errorCondition: ErrorCondition?, errorMessage: String?) -> Bool {
        guard let itemId = DBChatHistoryStore.instance.getItemId(for: account, with: jid, stanzaId: stanzaId) else {
            return false;
        }
        
        let params: [String: Any?] = ["id": itemId, "state": MessageState.outgoing_error_unread.rawValue, "error": errorMessage ?? errorCondition?.rawValue ?? "Unknown error"];
        guard try! self.markAsErrorStmt.update(params) > 0 else {
            return false;
        }
        DBChatStore.instance.newMessage(for: account, with: jid, timestamp: Date(timeIntervalSince1970: 0), message: nil, state: .outgoing_error_unread);
        itemUpdated(withId: itemId, for: account, with: jid);
        return true;
    }
    
    open func markAsRead(for account: BareJID, with jid: BareJID) {
        dispatcher.async {
            let params: [String: Any?] = ["account": account, "jid": jid];
            let updateRecords = try! self.markAsReadStmt.update(params);
            if updateRecords > 0 {
                DBChatStore.instance.markAsRead(for: account, with: jid);
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: DBChatHistoryStore.MESSAGES_MARKED_AS_READ, object: self, userInfo: ["account": account, "jid": jid]);
                }
            }
        }
    }
    
    open func getItemId(for account: BareJID, with jid: BareJID, stanzaId: String) -> Int? {
        return dispatcher.sync {
            let params: [String: Any?] = ["account": account, "jid": jid, "stanza_id": stanzaId];
            return try! self.getItemIdByStanzaId.scalar(params);
        }
    }

    open func updateItemState(for account: BareJID, with jid: BareJID, stanzaId: String, from oldState: MessageState, to newState: MessageState) {
        dispatcher.async {
            guard let msgId = self.getItemId(for: account, with: jid, stanzaId: stanzaId) else {
                return;
            }

            self.updateItemState(for: account, with: jid, itemId: msgId, from: oldState, to: newState);
        }
    }

    open func updateItemState(for account: BareJID, with jid: BareJID, itemId msgId: Int, from oldState: MessageState, to newState: MessageState) {
        dispatcher.async {
            let params: [String: Any?] = ["id": msgId, "oldState": oldState.rawValue, "newState": newState.rawValue];
            guard (try! self.updateItemStateStmt.update(params)) > 0 else {
                return;
            }
            self.itemUpdated(withId: msgId, for: account, with: jid);
        }
    }
    
    open func updateItem(for account: BareJID, with jid: BareJID, id: Int, preview: [String:String]? = nil) {
        dispatcher.async {
            var params: [String: Any?] = ["id": id];
            let test = Dictionary<String, String>(minimumCapacity: 2);
            if preview != nil {
                params["preview"] = preview!.map({ (k,v) -> String in
                    return "\(k)\t\(v)";
                }).joined(separator: "\n");
            }
            if try! self.updateItemStmt.update(params) > 0 {
                self.itemUpdated(withId: id, for: account, with: jid);
            }
        }
    }
    
    fileprivate func itemUpdated(withId id: Int, for account: BareJID, with jid: BareJID) {
        dispatcher.async {
            let params: [String: Any?] = ["id": id]
            try! self.getChatMessageWithIdStmt.query(params, forEach: { (cursor) in
                guard let item = self.itemFrom(cursor: cursor, for: account, with: jid) else {
                    return;
                }
                NotificationCenter.default.post(name: DBChatHistoryStore.MESSAGE_UPDATED, object: item);
            });
        }
    }
    
    open func getHistory(for account: BareJID, jid: BareJID, before: Int? = nil, limit: Int, completionHandler: @escaping (([ChatViewItemProtocol]) -> Void)) {
        dispatcher.async {
            if before != nil {
                let params: [String: Any?] = ["account": account, "jid": jid, "msgId": before!];
                let offset = try! self.getChatMessagePosition.scalar(params)!;
                completionHandler(self.getHistory(for: account, jid: jid, offset: offset, limit: limit));
            } else {
                completionHandler(self.getHistory(for: account, jid: jid, offset: 0, limit: limit));
            }
        }
    }
    
    open func getHistory(for account: BareJID, jid: BareJID, before: Int? = nil, limit: Int) -> [ChatViewItemProtocol] {
        return dispatcher.sync {
            if before != nil {
                let offset = try! getChatMessagePosition.scalar(["account": account, "jid": jid, "msgId": before!])!;
                return getHistory(for: account, jid: jid, offset: offset, limit: limit);
            } else {
                return getHistory(for: account, jid: jid, offset: 0, limit: limit);
            }
        }
    }
    
    fileprivate func getHistory(for account: BareJID, jid: BareJID, offset: Int, limit: Int) -> [ChatViewItemProtocol] {
        let params: [String: Any?] = ["account": account, "jid": jid, "offset": offset, "limit": limit];
        return try! getChatMessagesStmt.query(params) { (cursor) -> ChatViewItemProtocol? in
            return itemFrom(cursor: cursor, for: account, with: jid);
        }
    }
    
    fileprivate func checkItemAlreadyAdded(for account: BareJID, with jid: BareJID, authorNickname: String?, type: ItemType, timestamp: Date, direction: MessageDirection, stanzaId: String?, data: String) -> Bool {
        let range = stanzaId == nil ? 5.0 : 60.0;
        let ts_from = timestamp.addingTimeInterval(-60 * range);
        let ts_to = timestamp.addingTimeInterval(60 * range);
        
        let params: [String: Any?] = ["account": account, "jid": jid, "ts_from": ts_from, "ts_to": ts_to, "item_type": type.rawValue, "direction": direction.rawValue, "stanza_id": stanzaId, "data": data, "author_nickname": authorNickname];
        
        return (try! checkItemAlreadyAddedStmt.scalar(params) ?? 0) > 0;
    }
    
    fileprivate func itemFrom(cursor: DBCursor, for account: BareJID, with jid: BareJID) -> ChatViewItemProtocol? {
        let id: Int = cursor["id"]!;
        let stateInt: Int = cursor["state"]!;
        let timestamp: Date = cursor["timestamp"]!;
        let message: String = cursor["data"]!;
        let authorNickname: String? = cursor["author_nickname"];
        let authorJid: BareJID? = cursor["author_jid"];
        
        var preview: [String: String]? = nil;
        if let previewStr: String = cursor["preview"] {
            preview = [:];
            previewStr.split(separator: "\n").forEach { (line) in
                let tmp = line.split(separator: "\t");
                preview?[String(tmp[0])] = String(tmp[1]);
            }
        }
        return ChatMessage(id: id, timestamp: timestamp, account: account, jid: jid, state: MessageState(rawValue: stateInt)!, message: message, authorNickname: authorNickname, authorJid: authorJid, preview: preview);
    }
}

public enum ItemType: Int {
    case message = 0
}
