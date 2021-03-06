//
//  DataRealmCache.swift
//  SwiftyPress
//
//  Created by Basem Emara on 2018-10-16.
//  Copyright © 2019 Zamzam Inc. All rights reserved.
//

import Foundation
import RealmSwift
import ZamzamCore

public struct DataRealmCache: DataCache {
    private let fileManager: FileManager
    private let preferences: Preferences
    private let log: LogRepository
    
    public init(
        fileManager: FileManager,
        preferences: Preferences,
        log: LogRepository
    ) {
        self.fileManager = fileManager
        self.preferences = preferences
        self.log = log
    }
}

private extension DataRealmCache {
    
    /// Name for isolated database per user or use anonymously
    var name: String {
        generateName(for: preferences.userID ?? 0)
    }
    
    /// Used for referencing databases not associated with the current user
    func generateName(for userID: Int) -> String {
        "user_\(userID)"
    }
}

private extension DataRealmCache {
    
    var fileURL: URL? {
        folderURL?.appendingPathComponent("\(name).realm")
    }
    
    var folderURL: URL? {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Realm")
    }
}

public extension DataRealmCache {
    
    func configure() {
        DispatchQueue.database.sync {
            // Validate before initializing database
            guard let fileURL = fileURL, let folderURL = folderURL,
                // Skip if already set up before
                Realm.Configuration.defaultConfiguration.fileURL != fileURL else {
                    return
            }
            
            // Set the configuration used for user's Realm
            Realm.Configuration.defaultConfiguration = Realm.Configuration(
                fileURL: fileURL,
                deleteRealmIfMigrationNeeded: true,
                shouldCompactOnLaunch: { totalBytes, usedBytes in
                    // Compact if the file is over X MB in size and less than 50% 'used'
                    // https://realm.io/docs/swift/latest/#compacting-realms
                    let maxSize = 100 * 1024 * 1024 //100MB
                    let shouldCompact = (totalBytes > maxSize) && (Double(usedBytes) / Double(totalBytes)) < 0.5
                    
                    if shouldCompact {
                        self.log.warning("Compacting Realm database.")
                    }
                    
                    return shouldCompact
                }
            )
            
            defer {
                // Attempt to initialize and clean if necessary
                do {
                    _ = try Realm()
                } catch {
                    log.error("Could not initialize Realm database: \(error). Deleting database and recreating...")
                    _delete(for: preferences.userID ?? 0)
                    _ = try? Realm()
                }
                
                log.debug("Realm database initialized at: ~/\(fileURL.pathComponents.dropFirst(3).joined(separator: "/")).")
                log.info("Realm database configured for \(name).")
            }
            
            // Create default location, set permissions, and seed if applicable
            guard !fileManager.fileExists(atPath: folderURL.path) else { return }

            // Set permissions for database for background tasks
            do {
                // Create directory if does not exist yet
                try fileManager.createDirectory(atPath: folderURL.path, withIntermediateDirectories: true, attributes: nil)
                
                #if !os(macOS)
                // Decrease file protection after first open for the parent directory
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: folderURL.path
                )
                #endif
            } catch {
                log.error("Could not set permissions to Realm folder: \(error).")
            }
        }
    }
}

public extension DataRealmCache {
    
    var lastFetchedAt: Date? {
        getSyncActivity(for: SeedPayload.self)?.lastFetchedAt
    }
    
    func createOrUpdate(with request: DataAPI.CacheRequest, completion: @escaping (Result<SeedPayload, SwiftyPressError>) -> Void) {
        // Ensure there is data before proceeding
        guard !request.payload.isEmpty else {
            log.debug("No modified data to cache.")
            DispatchQueue.main.async { completion(.success(request.payload)) }
            return
        }
        
        // Write source data to local storage
        DispatchQueue.database.async {
            let realm: Realm
            
            do {
                realm = try Realm()
            } catch {
                DispatchQueue.main.async { completion(.failure(.cacheFailure(error))) }
                return
            }
            
            // Transform data
            let post = request.payload.posts.map { PostRealmObject(from: $0) }
            let media = request.payload.media.map { MediaRealmObject(from: $0) }
            let authors = request.payload.authors.map { AuthorRealmObject(from: $0) }
            let terms = request.payload.terms.map { TermRealmObject(from: $0) }
            
            do {
                try realm.write {
                    realm.add(post, update: .modified)
                    realm.add(media, update: .modified)
                    realm.add(authors, update: .modified)
                    realm.add(terms, update: .modified)
                }
                
                // Persist sync date for next use if applicable
                try self.updateSyncActivity(
                    for: SeedPayload.self,
                    lastFetchedAt: request.lastFetchedAt,
                    with: realm
                )
                
                self.log.debug("Cache modified data complete for "
                    + "\(post.count) posts, \(media.count) media, \(authors.count) authors, and \(terms.count) terms.")
                
                DispatchQueue.main.async { completion(.success(request.payload)) }
                return
            } catch {
                self.log.error("Could not write modified data to Realm from the source: \(error)")
                DispatchQueue.main.async { completion(.failure(.cacheFailure(error))) }
                return
            }
        }
    }
}

public extension DataRealmCache {
    
    func delete(for userID: Int) {
        DispatchQueue.database.sync {
            _delete(for: userID)
        }
    }
    
    /// Delete without thread.
    private func _delete(for userID: Int) {
        guard let directory = folderURL?.path else { return }
        
        do {
            let filenames = try fileManager.contentsOfDirectory(atPath: directory)
            let currentName = generateName(for: userID)
            
            try filenames
                .filter { $0.hasPrefix("\(currentName).") }
                .forEach { filename in
                    try fileManager.removeItem(atPath: "\(directory)/\(filename)")
                }
            
            log.warning("Deleted Realm database at: \(directory)/\(currentName).realm")
        } catch {
            log.error("Could not delete user's database: \(error)")
        }
    }
}

// MARK: - Helpers

private extension DataRealmCache {
    
    /// Get sync activity for type.
    func getSyncActivity<T>(for type: T.Type) -> SyncActivity? {
        let realm: Realm
        let typeName = String(describing: type)
        
        do {
            realm = try Realm()
        } catch {
            log.error("Could not initialize database: \(error)")
            return nil
        }
        
        return realm.object(ofType: SyncActivity.self, forPrimaryKey: typeName)
    }
    
    /// Update or create last fetched at date for sync activity.
    func updateSyncActivity<T>(for type: T.Type, lastFetchedAt: Date, with realm: Realm) throws {
        let typeName = String(describing: type)
        
        try realm.write {
            realm.create(SyncActivity.self, value: [
                "type": typeName,
                "lastFetchedAt": lastFetchedAt
            ], update: .modified)
        }
    }
}
