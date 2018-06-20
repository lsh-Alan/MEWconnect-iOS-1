//
//  BackupWordsInteractorInput.h
//  MyEtherWallet-iOS
//
//  Created by Mikhail Nikanorov on 23/05/2018.
//  Copyright © 2018 MyEtherWallet, Inc. All rights reserved.
//

@import Foundation;

@protocol BackupWordsInteractorInput <NSObject>
- (void) configurateWithMnemonics:(NSArray <NSString *> *)mnemonics;
- (NSArray <NSString *> *) recoveryMnemonicsWords;
- (void) subscribeToEvents;
- (void) unsubscribeFromEvents;
@end
