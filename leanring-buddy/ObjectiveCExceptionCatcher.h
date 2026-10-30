//
//  ObjectiveCExceptionCatcher.h
//  leanring-buddy
//
//  Swift can't catch Objective-C exceptions, and some Apple APIs throw them
//  instead of returning errors. AVAudioEngine's installTap does when the
//  microphone changed under it (headphones connecting). Uncaught, the
//  exception tears through Swift code mid-task and leaves Clicky stuck, so
//  calls like that run inside this catcher, which turns the exception into an
//  ordinary Swift error.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjectiveCExceptionCatcher : NSObject

/// Runs the block. If it raises an Objective-C exception, returns NO and an
/// error whose description is the exception's name and reason.
+ (BOOL)runCatchingExceptions:(NS_NOESCAPE void (^)(void))block
                        error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(run(catchingExceptionsIn:));

@end

NS_ASSUME_NONNULL_END
