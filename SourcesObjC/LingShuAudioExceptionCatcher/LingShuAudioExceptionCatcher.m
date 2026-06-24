#import "LingShuAudioExceptionCatcher.h"

BOOL LingShuCatchNSException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
