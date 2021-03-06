//
//  TestCase.swift
//  SwiftyPress
//
//  Created by Basem Emara on 2018-06-12.
//

#if !os(watchOS)
import XCTest
import ZamzamCore
@testable import SwiftyPress

class TestCase: XCTestCase {
    private lazy var dataRepository = core.dataRepository()
    private lazy var preferences = core.preferences()
    
    lazy var core: SwiftyPressCore = TestCore()
    
    override func setUp() {
        super.setUp()
        
        // Apple bug: doesn't work when running tests in batches
        // https://bugs.swift.org/browse/SR-906
        continueAfterFailure = false
        
        // Clear previous
        dataRepository.resetCache(for: preferences.userID ?? 0)
        preferences.removeAll()
        
        // Setup database
        dataRepository.configure()
    }
}
#endif
