//
//  DoraemonBacktraceLogger.h
//  DoraemonKit
//
//  Created by didi on 2020/3/18.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define DoraemonBSLOG NSLog(@"%@",[BSBacktraceLogger bs_backtraceOfCurrentThread]);
#define DoraemonBSLOG_MAIN NSLog(@"%@",[BSBacktraceLogger bs_backtraceOfMainThread]);
#define DoraemonBSLOG_ALL NSLog(@"%@",[BSBacktraceLogger bs_backtraceOfAllThread]);

@interface DoraemonBacktraceLogger : NSObject
/// 获取所有线程的堆栈
+ (NSString *)doraemon_backtraceOfAllThread;
/// 获取当前线程的堆栈
+ (NSString *)doraemon_backtraceOfCurrentThread;
/// 获取主线程的堆栈
+ (NSString *)doraemon_backtraceOfMainThread;
/// 获取指定线程的堆栈
+ (NSString *)doraemon_backtraceOfNSThread:(NSThread *)thread;

@end

NS_ASSUME_NONNULL_END
