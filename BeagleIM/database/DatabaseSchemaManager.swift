//
// DatabaseSchemaManager.swift
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

public class DBSchemaManager {
    
    static let CURRENT_VERSION = 1;
    
    fileprivate let dbConnection: DBConnection;
    
    init(dbConnection: DBConnection) {
        self.dbConnection = dbConnection;
    }
    
    open func upgradeSchema() throws {
        var version = try! getSchemaVersion();
        while (version < DBSchemaManager.CURRENT_VERSION) {
            try loadSchemaFile(fileName: "/db-schema-\(version + 1).sql");
            version = try! getSchemaVersion();
        }
        
        let duplicatedStmt = try! dbConnection.prepareStatement("select account, jid, count(id) from chats group by account, jid");
        let to_remove: [[String: BareJID]] = try! duplicatedStmt.query { (cursor) -> [String: BareJID]? in
            let account: BareJID = cursor[0]!;
            let jid: BareJID = cursor[1]!;
            let count: Int = cursor[2];
            print("found account =", account, ", jid =", jid, ", count =", count);
            guard count > 1 else {
                return nil;
            }
            print("found account =", account, ", jid =", jid, "to remove!");
            return ["account": account, "jid": jid];
        }
        to_remove.forEach({ params in
            try! dbConnection.execute("delete from chats where account = '\(params["account"]!.stringValue)' and jid = '\(params["jid"]!.stringValue)'");
        })
    }
    
    open func getSchemaVersion() throws -> Int {
        return try self.dbConnection.prepareStatement("PRAGMA user_version").scalar() ?? 0;
    }
    
    fileprivate func loadSchemaFile(fileName: String) throws {
        let resourcePath = Bundle.main.resourcePath! + fileName;
        print("loading SQL from file", resourcePath);
        let dbSchema = try String(contentsOfFile: resourcePath, encoding: String.Encoding.utf8);
        print("read schema:", dbSchema);
        try dbConnection.execute(dbSchema);
        print("loaded schema from file", fileName);
    }
    
}
