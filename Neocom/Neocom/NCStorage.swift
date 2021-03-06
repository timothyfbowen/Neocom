//
//  NCStorage.swift
//  Neocom
//
//  Created by Artem Shimanski on 02.12.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

import Foundation
import CoreData
import EVEAPI
import CloudData
import Dgmpp

class NCStorage: NSObject {
	private(set) lazy var managedObjectModel: NSManagedObjectModel = {
		NSManagedObjectModel(contentsOf: Bundle.main.url(forResource: "NCStorage", withExtension: "momd")!)!
	}()
	
	private(set) lazy var viewContext: NSManagedObjectContext = {
		var viewContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
		viewContext.persistentStoreCoordinator = self.persistentStoreCoordinator
		NotificationCenter.default.addObserver(self, selector: #selector(NCCache.managedObjectContextDidSave(_:)), name: NSNotification.Name.NSManagedObjectContextDidSave, object: nil)
		return viewContext
	}()
	
	private(set) lazy var persistentStoreCoordinator: NSPersistentStoreCoordinator = {
		var persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: self.managedObjectModel)
		let directory = URL.init(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0])
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
		var url = directory.appendingPathComponent("store.sqlite")
		
		for i in 0...1 {
			do {
				try persistentStoreCoordinator.addPersistentStore(ofType: CloudStoreType,
				                                                  configurationName: nil,
				                                                  at: url,
				                                                  options: [CloudStoreOptions.recordZoneKey: "Neocom",
				                                                            CloudStoreOptions.binaryDataCompressionLevel: BinaryDataCompressionLevel.default,
				                                                            CloudStoreOptions.mergePolicyType: NSMergePolicyType.overwriteMergePolicyType])
				break
			} catch {
				try? FileManager.default.removeItem(at: url)
			}
		}
		
		return persistentStoreCoordinator
	}()
	
	static let sharedStorage: NCStorage? = NCStorage()
	
	override init() {
		super.init()
		NotificationCenter.default.addObserver(self, selector: #selector(oauth2TokenDidRefresh(_:)), name: .OAuth2TokenDidRefresh, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(oauth2TokenDidBecomeInvalid(_:)), name: .OAuth2TokenDidBecomeInvalid, object: nil)
	}
	
	deinit {
		NotificationCenter.default.removeObserver(self)
	}
	
	func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
		let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
		context.persistentStoreCoordinator = persistentStoreCoordinator
		context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
		context.perform {
			block(context)
			if (context.hasChanges) {
				do {
					try context.save()
				}
				catch {
//					let e = error as NSError
//					print("\(e.domain): \(e.code)")
//					print ("\(error)")
				}
			}
		}
	}
	
	func performTaskAndWait<T: Any>(_ block: @escaping (NSManagedObjectContext) -> T) -> T {
		let context = NSManagedObjectContext(concurrencyType: Thread.isMainThread ? .mainQueueConcurrencyType : .privateQueueConcurrencyType)
		context.persistentStoreCoordinator = persistentStoreCoordinator
		context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
		var v: T?
		context.performAndWait {
			v = block(context)
			if (context.hasChanges) {
				do {
					try context.save()
				}
				catch {
					print ("\(error)")
				}
			}

		}
		return v!
	}

	private(set) lazy var accounts: NCFetchedCollection<NCAccount> = {
		return NCAccount.accounts(managedObjectContext: self.viewContext)
	}()

	private(set) lazy var fitCharacters: NCFetchedCollection<NCFitCharacter> = {
		return NCFitCharacter.fitCharacters(managedObjectContext: self.viewContext)
	}()

	//MARK: Private
	
	@objc func managedObjectContextDidSave(_ notification: Notification) {
		guard let context = notification.object as? NSManagedObjectContext else {return}
		if viewContext === context {
			if let account = NCAccount.current, (notification.userInfo?[NSDeletedObjectsKey] as? NSSet)?.contains(account) == true {
				NCAccount.current = nil
			}
		}
		else if context.persistentStoreCoordinator === viewContext.persistentStoreCoordinator {
			viewContext.perform {
				self.viewContext.mergeChanges(fromContextDidSave: notification)
				if self.viewContext.hasChanges {
					try? self.viewContext.save()
				}
			}
		}
	}
	
	@objc func oauth2TokenDidRefresh(_ notification: Notification) {
		guard let token = notification.object as? OAuth2Token else {return}
		performBackgroundTask { managedObjectContext in
			let request = NSFetchRequest<NCAccount>(entityName: "Account")
			request.predicate = NSPredicate(format: "refreshToken == %@", token.refreshToken)
			guard let account = (try? managedObjectContext.fetch(request))?.last else {return}
			account.token = token
		}
	}
	
	@objc func oauth2TokenDidBecomeInvalid(_ notification: Notification) {
		guard let token = notification.object as? OAuth2Token else {return}
		performBackgroundTask { managedObjectContext in
			let request = NSFetchRequest<NCAccount>(entityName: "Account")
			request.predicate = NSPredicate(format: "refreshToken == %@", token.refreshToken)
			guard let account = (try? managedObjectContext.fetch(request))?.last else {return}
			account.refreshToken = ""
			account.accessToken = ""
			(account.scopes as? Set<NCScope>)?.forEach { $0.managedObjectContext?.delete($0)}
		}
	}
}

enum NCItemFlag: Int32 {
	case hiSlot
	case medSlot
	case lowSlot
	case rigSlot
	case subsystemSlot
	case service
	case drone
	case cargo
	case hangar
	
	init?(flag: ESI.Assets.Asset.Flag) {
		switch flag {
		case .hiSlot0, .hiSlot1, .hiSlot2, .hiSlot3, .hiSlot4, .hiSlot5, .hiSlot6, .hiSlot7:
			self = .hiSlot
		case .medSlot0, .medSlot1, .medSlot2, .medSlot3, .medSlot4, .medSlot5, .medSlot6, .medSlot7:
			self = .medSlot
		case .loSlot0, .loSlot1, .loSlot2, .loSlot3, .loSlot4, .loSlot5, .loSlot6, .loSlot7:
			self = .lowSlot
		case .rigSlot0, .rigSlot1, .rigSlot2, .rigSlot3, .rigSlot4, .rigSlot5, .rigSlot6, .rigSlot7:
			self = .rigSlot
		case .subSystemSlot0, .subSystemSlot1, .subSystemSlot2, .subSystemSlot3, .subSystemSlot4, .subSystemSlot5, .subSystemSlot6, .subSystemSlot7:
			self = .subsystemSlot
		case .droneBay, .fighterBay, .fighterTube0, .fighterTube1, .fighterTube2, .fighterTube3, .fighterTube4:
			self = .drone
		case .hangar, .fleetHangar, .hangarAll, .shipHangar, .specializedLargeShipHold, .specializedIndustrialShipHold, .specializedMediumShipHold, .specializedShipHold, .specializedSmallShipHold :
			self = .hangar
		case .cargo, .corpseBay, .specializedAmmoHold, .specializedCommandCenterHold, .specializedFuelBay, .specializedGasHold, .specializedMaterialBay, .specializedMineralHold, .specializedOreHold, .specializedPlanetaryCommoditiesHold, .specializedSalvageHold:
			self = .cargo
		default:
			return nil
		}

	}
	
	var image: UIImage? {
		switch self {
		case .hiSlot:
			return DGMModule.Slot.hi.image
		case .medSlot:
			return DGMModule.Slot.med.image
		case .lowSlot:
			return DGMModule.Slot.low.image
		case .rigSlot:
			return DGMModule.Slot.rig.image
		case .subsystemSlot:
			return DGMModule.Slot.subsystem.image
		case .service:
			return DGMModule.Slot.service.image
		case .drone:
			return #imageLiteral(resourceName: "drone")
		case .cargo:
			return #imageLiteral(resourceName: "cargoBay")
		case .hangar:
			return #imageLiteral(resourceName: "ships")
		}
	}
	
	var title: String? {
		switch self {
		case .hiSlot:
			return DGMModule.Slot.hi.title
		case .medSlot:
			return DGMModule.Slot.med.title
		case .lowSlot:
			return DGMModule.Slot.low.title
		case .rigSlot:
			return DGMModule.Slot.rig.title
		case .subsystemSlot:
			return DGMModule.Slot.subsystem.title
		case .service:
			return DGMModule.Slot.service.title
		case .drone:
			return NSLocalizedString("Drones", comment: "")
		case .cargo:
			return NSLocalizedString("Cargo", comment: "")
		case .hangar:
			return NSLocalizedString("Hangar", comment: "")
		}
	}
	
}
