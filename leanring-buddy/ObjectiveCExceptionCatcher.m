//
//  ObjectiveCExceptionCatcher.m
//  leanring-buddy
//

#import "ObjectiveCExceptionCatcher.h"

@implementation ObjectiveCExceptionCatcher

+ (BOOL)runCatchingExceptions:(NS_NOESCAPE void (^)(void))block
                        error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *caughtException) {
        if (error) {
            NSString *exceptionDescription = [NSString stringWithFormat:@"%@: %@",
                caughtException.name, caughtException.reason ?: @"no reason given"];
            *error = [NSError errorWithDomain:@"ObjectiveCException"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: exceptionDescription}];
        }
        return NO;
    }
}

@end
