#import "SPAppDelegate.h"
#import "Simplenote-Swift.h"

#import "SPConstants.h"

#import "SPNavigationController.h"
#import "SPNoteListViewController.h"
#import "SPNoteEditorViewController.h"
#import "SPSettingsViewController.h"
#import "SPTagsListViewController.h"
#import "SPAddCollaboratorsViewController.h"

#import "NSManagedObjectContext+CoreDataExtensions.h"
#import "NSProcessInfo+Util.h"
#import "SPModalActivityIndicator.h"
#import "SPEditorTextView.h"

#import "SPObjectManager.h"
#import "Note.h"
#import "Tag.h"
#import "Settings.h"
#import "SPRatingsHelper.h"
#import "WPAuthHandler.h"

#import "DTPinLockController.h"
#import "SPTracker.h"

@import Contacts;
@import Simperium;

@class KeychainMigrator;

#if USE_APPCENTER
@import AppCenter;
@import AppCenterDistribute;
#endif


#pragma mark ================================================================================
#pragma mark Private Properties
#pragma mark ================================================================================

@interface SPAppDelegate () <SPBucketDelegate, PinLockDelegate>

@property (strong, nonatomic) Simperium                     *simperium;
@property (strong, nonatomic) NSManagedObjectContext        *managedObjectContext;
@property (strong, nonatomic) NSManagedObjectModel          *managedObjectModel;
@property (strong, nonatomic) NSPersistentStoreCoordinator  *persistentStoreCoordinator;
@property (weak,   nonatomic) SPModalActivityIndicator      *signOutActivityIndicator;

@end


#pragma mark ================================================================================
#pragma mark Simplenote AppDelegate
#pragma mark ================================================================================

@implementation SPAppDelegate

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


#pragma mark ================================================================================
#pragma mark Frameworks Setup
#pragma mark ================================================================================

- (void)setupSimperium
{
	self.simperium = [[Simperium alloc] initWithModel:self.managedObjectModel context:self.managedObjectContext coordinator:self.persistentStoreCoordinator];
		  
#if USE_VERBOSE_LOGGING
    [_simperium setVerboseLoggingEnabled:YES];
    NSLog(@"verbose logging enabled");
#else
    [_simperium setVerboseLoggingEnabled:NO];
#endif
    
    _simperium.authenticationViewControllerClass    = [SPOnboardingViewController class];
    _simperium.authenticator.providerString         = @"simplenote.com";
	

    [_simperium setAuthenticationShouldBeEmbeddedInNavigationController:YES];
    [_simperium setAllBucketDelegates:self];
    [_simperium setDelegate:self];
    
    NSArray *buckets = @[NSStringFromClass([Note class]),
                         NSStringFromClass([Tag class]),
                         NSStringFromClass([Settings class])];
    
    for (NSString *bucketName in buckets) {
        [_simperium bucketForName:bucketName].notifyWhileIndexing = YES;
    }
}

- (void)authenticateSimperium
{
	NSAssert(self.navigationController, nil);
	[_simperium authenticateWithAppID:[SPCredentials simperiumAppID] APIKey:[SPCredentials simperiumApiKey] rootViewController:self.navigationController];
}

- (void)setupDefaultWindow
{
    if (!self.window) {
        self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    }
    
    self.window.backgroundColor = [UIColor simplenoteWindowBackgroundColor];
    self.window.tintColor = [UIColor simplenoteTintColor];

    // check to see if the app terminated with a previously selected tag
    NSString *selectedTag = [[NSUserDefaults standardUserDefaults] objectForKey:kSelectedTagKey];
    if (selectedTag != nil) {
		[self setSelectedTag:selectedTag];
	}

    self.tagListViewController = [SPTagsListViewController new];
    self.noteListViewController = [SPNoteListViewController new];

    self.navigationController = [[SPNavigationController alloc] initWithRootViewController:_noteListViewController];

    self.sidebarViewController = [[SPSidebarContainerViewController alloc] initWithMainViewController:self.navigationController
                                                                                sidebarViewController:self.tagListViewController];
    self.sidebarViewController.delegate = self.noteListViewController;

    self.window.rootViewController = self.sidebarViewController;
    
    [self.window makeKeyAndVisible];
}

- (void)setupAppCenter
{
#if USE_APPCENTER
    NSLog(@"Initializing AppCenter...");
    
    NSString *identifier = [SPCredentials appCenterIdentifier];
    [MSAppCenter start:identifier withServices:@[[MSDistribute class]]];
    [MSDistribute setEnabled:true];
#endif
}

- (void)setupCrashLogging
{
    [CrashLogging startWithSimperium: self.simperium];
}

- (void)setupThemeNotifications
{
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(themeDidChange) name:SPSimplenoteThemeChangedNotification object:nil];
}


#pragma mark ================================================================================
#pragma mark AppDelegate Methods
#pragma mark ================================================================================

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id> *)launchOptions
{
    // Migrate keychain items
    KeychainMigrator *keychainMigrator = [[KeychainMigrator alloc] init];
// Keychain Migration Testing: Should only run in *release* targets. Uncomment / use at will
//    [keychainMigrator testMigration];
    [keychainMigrator migrateIfNecessary];

    // Setup Frameworks
    [self setupThemeNotifications];
    [self setupSimperium];
    [self setupAppCenter];
    [self setupCrashLogging];
    [self configureVersionsController];
    [self setupDefaultWindow];
    [self configureStateRestoration];

    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	// Once the UI is wired, Auth Simperium
	[self authenticateSimperium];

    // Handle Simplenote Migrations: We *need* to initialize the Ratings framework after this step, for reasons be.
    [[MigrationsHandler new] ensureUpdateIsHandled];
    [self setupAppRatings];
    
    // Initialize UI
    [self loadLastSelectedNote];
    [self loadSelectedTheme];
    
    // Check to see if first time user
    if ([self isFirstLaunch]) {        
        [self removePin];
        [self createWelcomeNoteAfterDelay];
        [self markFirstLaunch];
    } else {
        [self showPasscodeLockIfNecessary];
    }

    // Index (All of the) Spotlight Items if the user upgraded
    [self indexSpotlightItemsIfNeeded];

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    [self ensurePinlockIsDismissed];
    [SPTracker trackApplicationOpened];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [SPTracker trackApplicationClosed];
}

- (void)ensurePinlockIsDismissed
{
    // Dismiss the pin lock window if the user has returned to the app before their preferred timeout length
    if (self.pinLockWindow != nil
        && [self.pinLockWindow isKeyWindow]
        && [SPPinLockManager shouldBypassPinLock]) {
        // Bring the main window to the front, which 'dismisses' the pin lock window
        [self.window makeKeyAndVisible];
        [self.pinLockWindow removeFromSuperview];
        self.pinLockWindow = nil;
    }
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> * _Nullable))restorationHandler
{
    return [[ShortcutsHandler shared] handleUserActivity:userActivity];
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    // For the passcode lock, store the current clock time for comparison when returning to the app
    if ([self passcodeLockIsEnabled] && [self.window isKeyWindow]) {
        [SPPinLockManager storeLastUsedTime];
    }
    
    [self showPasscodeLockIfNecessary];
    UIViewController *viewController = self.window.rootViewController;
    [viewController.view setNeedsLayout];
    
    // Save any pending changes
    [self.noteEditorViewController save];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Save the current note and tag
    if (_selectedTag) {
        [[NSUserDefaults standardUserDefaults] setObject:_selectedTag forKey:kSelectedTagKey];
    }
    
    NSString *currentNoteKey = self.noteEditorViewController.currentNote.simperiumKey;
    if (currentNoteKey) {
        [[NSUserDefaults standardUserDefaults] setObject:currentNoteKey forKey:kSelectedNoteKey];
    }
    
    // Save any pending changes
    [self.noteEditorViewController save];
}

// Deprecated in iOS 13.2. Per the docs, this method will not be called in favor of the new secure version when both are defined.
- (BOOL)application:(UIApplication *)application shouldSaveApplicationState:(NSCoder *)coder
{
    return YES;
}

- (BOOL)application:(UIApplication *)application shouldSaveSecureApplicationState:(NSCoder *)coder
{
    return YES;
}

// Deprecated in iOS 13.2. Per the docs, this method will not be called in favor of the new secure version when both are defined.
- (BOOL)application:(UIApplication *)application shouldRestoreApplicationState:(NSCoder *)coder
{
    return YES;
}

- (BOOL)application:(UIApplication *)application shouldRestoreSecureApplicationState:(NSCoder *)coder
{
    return YES;
}


#pragma mark - First Launch

- (BOOL)isFirstLaunch
{
    return [[Options shared] firstLaunch] == NO;
}

- (void)markFirstLaunch
{
    [[Options shared] setFirstLaunch:YES];
}

- (void)createWelcomeNoteAfterDelay
{
    [self performSelector:@selector(createWelcomeNote) withObject:nil afterDelay:0.5];
}

- (void)createWelcomeNote
{
    NSString *welcomeKey = @"welcomeNote-iOS";
    SPBucket *noteBucket = [_simperium bucketForName:@"Note"];
    Note *welcomeNote = [noteBucket objectForKey:welcomeKey];
    
    if (welcomeNote) {
        return;
	}
    
    welcomeNote = [noteBucket insertNewObjectForKey:welcomeKey];
    welcomeNote.modificationDate = [NSDate date];
    welcomeNote.creationDate = [NSDate date];
    welcomeNote.content = NSLocalizedString(@"welcomeNote-iOS", @"A welcome note for new iOS users");
    [self save];
    
    _noteListViewController.firstLaunch = YES;
}


#pragma mark - Launch Helpers

- (void)loadLastSelectedNote
{
    NSString *selectedNoteKey = [[NSUserDefaults standardUserDefaults] objectForKey:kSelectedNoteKey];
    if (selectedNoteKey) {
        [self.noteListViewController openNoteWithSimperiumKey:selectedNoteKey animated:NO];
    }

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedNoteKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedTagKey];
}

- (void)loadSelectedTheme
{
    [[SPUserInterface shared] refreshUserInterfaceStyle];
}


#pragma mark - Theme's

- (void)themeDidChange
{
    self.window.backgroundColor = [UIColor simplenoteBackgroundColor];
    self.window.tintColor = [UIColor simplenoteTintColor];
}


#pragma mark ================================================================================
#pragma mark Core Data stack
#pragma mark ================================================================================

- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext != nil) {
        return _managedObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (coordinator != nil) {
        _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        [_managedObjectContext setUndoManager:nil];
    }
    return _managedObjectContext;
}

- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel != nil) {
        return _managedObjectModel;
    }
	
    NSURL *modelURL = [NSURL fileURLWithPath: [[NSBundle mainBundle]  pathForResource:@"Simplenote" ofType:@"momd"]];
    _managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    return _managedObjectModel;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator != nil) {
        return _persistentStoreCoordinator;
    }
    
    //NSURL *storeURL = [[self applicationDocumentsDirectory] URLByAppendingPathComponent:@"Simplenote.sqlite"];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *path = [documentsDirectory stringByAppendingPathComponent:@"Simplenote.sqlite"];
    NSURL *storeURL = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    
    // Perform automatic, lightweight migration
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption, [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];
    
    if (![_persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:&error])
    {
        NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
        abort();
    }

    return _persistentStoreCoordinator;
}


#pragma mark ================================================================================
#pragma mark Other
#pragma mark ================================================================================

- (void)dismissAllModalsAnimated:(BOOL)animated completion:(void(^)())completion
{
    [self.navigationController dismissViewControllerAnimated:animated
                                                  completion:^{
                                                      
                                                      if (completion) {
                                                          completion();
                                                      }
                                                  }];
    
}

- (void)presentSettingsViewController
{
    SPSettingsViewController *settingsViewController = [SPSettingsViewController new];
	
    SPNavigationController *navController = [[SPNavigationController alloc] initWithRootViewController:settingsViewController];
    navController.disableRotation = YES;
    navController.displaysBlurEffect = YES;
    navController.modalPresentationStyle = UIModalPresentationFormSheet;
    navController.modalPresentationCapturesStatusBarAppearance = YES;
    
    [self.sidebarViewController presentViewController:navController animated:YES completion:nil];
}

- (void)logoutAndReset:(id)sender
{
    self.bSigningUserOut = YES;
    self.signOutActivityIndicator = [SPModalActivityIndicator show];
    
    // Remove WordPress token
    [SPKeychain deletePasswordForService:kSimplenoteWPServiceName account:self.simperium.user.email];

    // Remove Siri Shortcuts
    [[ShortcutsHandler shared] unregisterSimplenoteActivities];

    // Actual Simperium Logout
    double delayInSeconds = 0.75;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){

        [self.simperium signOutAndRemoveLocalData:YES completion:^{

            [self.navigationController popToRootViewControllerAnimated:YES];
            self.selectedTag = nil;
            [self.noteListViewController update];
			
			NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
			[defaults removeObjectForKey:kSelectedNoteKey];
			[defaults removeObjectForKey:kSelectedTagKey];
			[defaults synchronize];
			
            [[CSSearchableIndex defaultSearchableIndex] deleteAllSearchableItemsWithCompletionHandler:nil];
            
            // Nuke all of the User Preferences
            [[Options shared] reset];
            
			// remove the pin lock
			[self removePin];
			
			// hide sidebar of notelist
            [self.sidebarViewController hideSidebarWithAnimation:NO];
			
			[self dismissAllModalsAnimated:YES completion:^{
				
                [self.simperium authenticateIfNecessary];
                self.bSigningUserOut = NO;
			}];
		}];
    });
}

- (void)save
{
    [self.simperium save];
}


#pragma mark ================================================================================
#pragma mark SPBucket delegate
#pragma mark ================================================================================

- (void)bucket:(SPBucket *)bucket didChangeObjectForKey:(NSString *)key forChangeType:(SPBucketChangeType)change memberNames:(NSArray *)memberNames
{
    if ([bucket.name isEqualToString:NSStringFromClass([Note class])]) {
        // Note change
        switch (change) {
            case SPBucketChangeTypeUpdate:
            {
                if ([key isEqualToString:self.noteEditorViewController.currentNote.simperiumKey]) {
                    [self.noteEditorViewController didReceiveNewContent];
                }
                Note *note = [bucket objectForKey:key];
                if (note && !note.deleted) {
                    [[CSSearchableIndex defaultSearchableIndex] indexSearchableNote:note];
                } else {
                    [[CSSearchableIndex defaultSearchableIndex] deleteSearchableItemsWithIdentifiers:@[key] completionHandler:nil];
                }
            }
                break;
            case SPBucketChangeTypeInsert:
                break;
			case SPBucketChangeTypeDelete:
            {
                if ([key isEqualToString:self.noteEditorViewController.currentNote.simperiumKey]) {
                    [self.noteEditorViewController didDeleteCurrentNote];
                }
                [[CSSearchableIndex defaultSearchableIndex] deleteSearchableItemsWithIdentifiers:@[key] completionHandler:nil];
            }
				break;
            default:
                break;
        }
    } else if ([bucket.name isEqualToString:NSStringFromClass([Tag class])]) {
        // Tag deleted
        switch (change) {
            case SPBucketChangeTypeDelete:
            {
                // if selected tag is deleted, swap the note list view controller
                if ([key isEqual:self.selectedTag]) {
                    self.selectedTag = nil;
                    [self.noteListViewController update];
                }
                break;
            }
            default:
                break;
        }
    } else if ([bucket.name isEqualToString:NSStringFromClass([Settings class])]) {
        [[SPRatingsHelper sharedInstance] reloadSettings];
    }
}

- (void)bucket:(SPBucket *)bucket willChangeObjectsForKeys:(NSSet *)keys
{
    if ([bucket.name isEqualToString:@"Note"]) {
        for (NSString *key in keys) {
            if ([key isEqualToString:self.noteEditorViewController.currentNote.simperiumKey]) {
                [self.noteEditorViewController willReceiveNewContent];
            }
        }
    }
}

- (void)bucket:(SPBucket *)bucket didReceiveObjectForKey:(NSString *)key version:(NSString *)version data:(NSDictionary *)data
{
    if ([bucket.name isEqualToString:@"Note"]) {
        [self.versionsController didReceiveObjectForSimperiumKey:key version:[version integerValue] data:data];
    }
}

- (void)bucketWillStartIndexing:(SPBucket *)bucket
{
    if ([bucket.name isEqualToString:@"Note"]) {
        [_noteListViewController setWaitingForIndex:YES];
    }
}

- (void)bucketDidFinishIndexing:(SPBucket *)bucket
{
    if ([bucket.name isEqualToString:@"Note"]) {
        [_noteListViewController setWaitingForIndex:NO];
        [self indexSpotlightItems];
    }
}


#pragma mark ================================================================================
#pragma mark Spotlight
#pragma mark ================================================================================

- (void)indexSpotlightItemsIfNeeded
{
    // This process should be executed *just once*, and only if the user is already logged in (AKA "Upgrade")
    NSString *kSpotlightDidRunKey = @"SpotlightDidRunKey";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if ([defaults boolForKey:kSpotlightDidRunKey] == true) {
        return;
    }

    [defaults setBool:true forKey:kSpotlightDidRunKey];
    [defaults synchronize];

    if (self.simperium.user.authenticated == false) {
        return;
    }

    [self indexSpotlightItems];
}

- (void)indexSpotlightItems
{
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [context setParentContext:self.simperium.managedObjectContext];
    
    [context performBlock:^{
        NSArray *deleted = [context fetchObjectsForEntityName:@"Note" withPredicate:[NSPredicate predicateWithFormat:@"deleted == YES"]];
        [[CSSearchableIndex defaultSearchableIndex] deleteSearchableNotes:deleted];
        
        NSArray *notes = [context fetchObjectsForEntityName:@"Note" withPredicate:[NSPredicate predicateWithFormat:@"deleted == NO"]];
        [[CSSearchableIndex defaultSearchableIndex] indexSearchableNotes:notes];
    }];
}


#pragma mark ================================================================================
#pragma mark URL scheme
#pragma mark ================================================================================

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    // URL: Open a Note!
    if ([self handleOpenNoteWithUrl:url]) {
        return YES;
    }

    // Support opening Simplenote and optionally creating a new note
    if ([[url host] isEqualToString:@"new"]) {
        
        Note *newNote = (Note *)[NSEntityDescription insertNewObjectForEntityForName:@"Note"
                                                              inManagedObjectContext:self.managedObjectContext];
        newNote.creationDate = [NSDate date];
        newNote.modificationDate = [NSDate date];
        
        NSArray *params = [[url query] componentsSeparatedByString:@"&"];
        for (NSString *param in params) {
            NSArray *paramArray = [param componentsSeparatedByString:@"="];
            if ([paramArray count] < 2) {
                continue;
            }
            
            NSString *key = [paramArray objectAtIndex:0];
            NSString *value = [[paramArray objectAtIndex:1] stringByRemovingPercentEncoding];
            
            if ([key isEqualToString:@"content"]) {
                newNote.content = value;
            } else if ([key isEqualToString:@"tag"]) {
                NSArray *tags = [value componentsSeparatedByString:@" "];
                for (NSString *tag in tags) {
                    if (tag.length == 0)
                        continue;
                    [newNote addTag:tag];
                    [[SPObjectManager sharedManager] createTagFromString:tag];
                }
            }
        }
        [_simperium save];
        
        [self presentNote:newNote];
    } else if ([WPAuthHandler isWPAuthenticationUrl: url]) {
        if (self.simperium.user.authenticated) {
            // We're already signed in
            [[NSNotificationCenter defaultCenter] postNotificationName:kSignInErrorNotificationName
                                                                object:nil];
            return NO;
        }
        
        SPUser *newUser = [WPAuthHandler authorizeSimplenoteUserFromUrl:url forAppId:[SPCredentials simperiumAppID]];
        if (newUser != nil) {
            self.simperium.user = newUser;
            [self.navigationController dismissViewControllerAnimated:YES completion:nil];
            [self.simperium authenticationDidSucceedForUsername:newUser.email token:newUser.authToken];
            
            [SPTracker trackWPCCLoginSucceeded];
        }
    }
    
    return YES;
}

- (void)presentNoteWithUniqueIdentifier:(NSString *)uuid
{
    Note *note = [self.simperium loadNoteWithSimperiumKey:uuid];
    if (note == nil) {
        return;
    }

    [self presentNote:note];
}

- (void)presentNewNoteEditor
{
    [self presentNote:nil];
}

- (void)presentNote:(Note *)note
{
    // Hide any modals
    [self dismissAllModalsAnimated:NO completion:nil];
    
    // If root tag list is currently being viewed, push All Notes instead
    [self.sidebarViewController hideSidebarWithAnimation:NO];
    
    // Little trick to postpone until next run loop to ensure controllers have a chance to pop
    double delayInSeconds = 0.05;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self.noteListViewController openNote:note animated:NO];
        [self showPasscodeLockIfNecessary];
    });
}


#pragma mark ================================================================================
#pragma mark Passcode Lock
#pragma mark ================================================================================

- (UIViewController*)topMostController
{
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    
    return topController;
}

-(void)showPasscodeLockIfNecessary
{
    if (![self passcodeLockIsEnabled] || [self isPresentingPinLock] || [self isRequestingContactsPermission]) {
        return;
	}
    
    BOOL useBiometry = self.allowBiometryInsteadOfPin;
    DTPinLockController *controller = [[DTPinLockController alloc] initWithMode:useBiometry ? PinLockControllerModeUnlockAllowTouchID :PinLockControllerModeUnlock];
	controller.pinLockDelegate = self;
	controller.pin = [self getPin];
    controller.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
	
	// no animation to cover up app right away
    self.pinLockWindow = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.pinLockWindow.rootViewController = controller;
    [self.pinLockWindow makeKeyAndVisible];
	[controller fixLayout];
}

- (BOOL)passcodeLockIsEnabled {
    NSString *pin = [self getPin];
    
    return pin != nil && pin.length != 0;
}

- (void)pinLockControllerDidFinishUnlocking
{
    [UIView animateWithDuration:0.3
                     animations:^{ self.pinLockWindow.alpha = 0.0; }
                     completion:^(BOOL finished) {
                         [self.window makeKeyAndVisible];
                         [self.pinLockWindow removeFromSuperview];
                         self.pinLockWindow = nil;
                     }];
}

- (BOOL)allowBiometryInsteadOfPin
{
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    BOOL useTouchID = [userDefaults boolForKey:kSimplenoteUseBiometryKey];

    return useTouchID;
}

- (void)setAllowBiometryInsteadOfPin:(BOOL)allowBiometryInsteadOfPin
{
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    [userDefaults setBool:allowBiometryInsteadOfPin forKey:kSimplenoteUseBiometryKey];
    [userDefaults synchronize];
}

- (BOOL)isPresentingPinLock
{
    return self.pinLockWindow && [self.pinLockWindow isKeyWindow];
}

- (BOOL)isRequestingContactsPermission
{
    NSArray *topChildren = self.topMostController.childViewControllers;
    BOOL isShowingCollaborators = [topChildren count] > 0 && [topChildren[0] isKindOfClass:[SPAddCollaboratorsViewController class]];
    BOOL isNotDeterminedAuth = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts] == CNAuthorizationStatusNotDetermined;
    
    return isShowingCollaborators && isNotDeterminedAuth;
}


#pragma mark ================================================================================
#pragma mark App Tracking
#pragma mark ================================================================================

- (void)setupAppRatings
{
    // Dont start App Tracking if we are running the test suite
    if ([NSProcessInfo isRunningTests]) {
        return;
    }

    NSString *version = [[NSBundle mainBundle] shortVersionString];
    
    [[SPRatingsHelper sharedInstance] initializeForVersion:version];
    [[SPRatingsHelper sharedInstance] reloadSettings];
}


#pragma mark ================================================================================
#pragma mark Static Helpers
#pragma mark ================================================================================

+ (SPAppDelegate *)sharedDelegate
{
    return (SPAppDelegate *)[[UIApplication sharedApplication] delegate];
}

@end
