//
//  DoraemonBacktraceLogger.m
//  DoraemonKit
//
//  Created by didi on 2020/3/18.
//

#import "DoraemonBacktraceLogger.h"
#import <mach/mach.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/types.h>
#include <limits.h>
#include <string.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>

#pragma -mark DEFINE MACRO FOR DIFFERENT CPU ARCHITECTURE
#if defined(__arm64__)
/// 删除对齐位来获得地址指令，此架构下要删除两个最低有效位
#define Doraemon_DETAG_INSTRUCTION_ADDRESS(A) ((A) & ~(3UL))
/// 线程状态结构中的寄存器数量
#define Doraemon_THREAD_STATE_COUNT ARM_THREAD_STATE64_COUNT
/// 线程状态结构的类型
#define Doraemon_THREAD_STATE ARM_THREAD_STATE64
/// 保存帧指针的寄存器
#define Doraemon_FRAME_POINTER __fp
/// 保存堆栈指针的寄存器
#define Doraemon_STACK_POINTER __sp
/// 保存指令指针的寄存器
#define Doraemon_INSTRUCTION_ADDRESS __pc

#elif defined(__arm__)
/// 删除对齐位来获得地址指令，此架构下要删除一个最低有效位
#define Doraemon_DETAG_INSTRUCTION_ADDRESS(A) ((A) & ~(1UL))
/// 线程状态结构中的寄存器数量
#define Doraemon_THREAD_STATE_COUNT ARM_THREAD_STATE_COUNT
/// 线程状态结构的类型
#define Doraemon_THREAD_STATE ARM_THREAD_STATE
/// 保存帧指针的寄存器
#define Doraemon_FRAME_POINTER __r[7]
/// 保存堆栈指针的寄存器
#define Doraemon_STACK_POINTER __sp
/// 保存指令指针的寄存器
#define Doraemon_INSTRUCTION_ADDRESS __pc

#elif defined(__x86_64__)
/// 删除对齐位来获得地址指令，此架构下无需操作
#define Doraemon_DETAG_INSTRUCTION_ADDRESS(A) (A)
/// 线程状态结构中的寄存器数量
#define Doraemon_THREAD_STATE_COUNT x86_THREAD_STATE64_COUNT
/// 线程状态结构的类型
#define Doraemon_THREAD_STATE x86_THREAD_STATE64
/// 保存帧指针的寄存器
#define Doraemon_FRAME_POINTER __rbp
/// 保存堆栈指针的寄存器
#define Doraemon_STACK_POINTER __rsp
/// 保存指令指针的寄存器
#define Doraemon_INSTRUCTION_ADDRESS __rip

#elif defined(__i386__)
/// 删除对齐位来获得地址指令，此架构下无需操作
#define Doraemon_DETAG_INSTRUCTION_ADDRESS(A) (A)
/// 线程状态结构中的寄存器数量
#define Doraemon_THREAD_STATE_COUNT x86_THREAD_STATE32_COUNT
/// 线程状态结构的类型
#define Doraemon_THREAD_STATE x86_THREAD_STATE32
/// 保存帧指针的寄存器
#define Doraemon_FRAME_POINTER __ebp
/// 保存堆栈指针的寄存器
#define Doraemon_STACK_POINTER __esp
/// 保存指令指针的寄存器
#define Doraemon_INSTRUCTION_ADDRESS __eip

#endif
// 为什么要处理-1，不理解⚠️
#define Doraemon_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(A) (Doraemon_DETAG_INSTRUCTION_ADDRESS((A)) - 1)

#if defined(__LP64__)
#define Doraemon_TRACE_FMT         "%-4d%-31s 0x%016lx %s + %lu"
#define Doraemon_POINTER_FMT       "0x%016lx"
#define Doraemon_POINTER_SHORT_FMT "0x%lx"
#define Doraemon_NLIST struct nlist_64
#else
#define Doraemon_TRACE_FMT         "%-4d%-31s 0x%08lx %s + %lu"
#define Doraemon_POINTER_FMT       "0x%08lx"
#define Doraemon_POINTER_SHORT_FMT "0x%lx"
#define Doraemon_NLIST struct nlist
#endif

/// 栈帧结构
typedef struct DoraemonStackFrameEntry{
    /// 保存前一个栈帧
    const struct DoraemonStackFrameEntry *const previous;
    /// 保存当前帧的返回地址
    const uintptr_t return_address;
} DoraemonStackFrameEntry;

static mach_port_t main_thread_id;

@implementation DoraemonBacktraceLogger


+ (void)load {
    // 存储当前线程的mach端口
    main_thread_id = mach_thread_self();
}

#pragma -mark Implementation of interface
/// 获取指定线程的堆栈
+ (NSString *)doraemon_backtraceOfNSThread:(NSThread *)thread {
    return _doraemon_backtraceOfThread(doraemon_machThreadFromNSThread(thread));
}
/// 获取当前线程的堆栈
+ (NSString *)doraemon_backtraceOfCurrentThread {
    return [self doraemon_backtraceOfNSThread:[NSThread currentThread]];
}
/// 获取主线程的堆栈
+ (NSString *)doraemon_backtraceOfMainThread {
    return [self doraemon_backtraceOfNSThread:[NSThread mainThread]];
}
/// 获取所有线程的堆栈
+ (NSString *)doraemon_backtraceOfAllThread {
    // 声明储存线程的数组
    thread_act_array_t threads;
    // 声明储存线程数量的变量
    mach_msg_type_number_t thread_count = 0;
    // 获取当前进程相关的mach task的句柄
    const task_t this_task = mach_task_self();
    // 获取mach task的所有线程，并存储在对应变量中
    kern_return_t kr = task_threads(this_task, &threads, &thread_count);
    // 获取失败报错
    if(kr != KERN_SUCCESS) {
        return @"Fail to get information of all threads";
    }
    // 组装输出信息
    NSMutableString *resultString = [NSMutableString stringWithFormat:@"Call Backtrace of %u threads:\n", thread_count];
    // 遍历所有线程，依次将信息组装拼接
    for(int i = 0; i < thread_count; i++) {
        // 获取线程堆栈信息
        [resultString appendString:_doraemon_backtraceOfThread(threads[i])];
    }
    // 返回信息
    return [resultString copy];
}

#pragma -mark Get call backtrace of a mach_thread
/// 获取线程堆栈信息
NSString *_doraemon_backtraceOfThread(thread_t thread) {
    // 声明堆栈变量，容量为50个
    uintptr_t backtraceBuffer[50];
    int i = 0;
    NSMutableString *resultString = [[NSMutableString alloc] initWithFormat:@"Backtrace of Thread %u:\n", thread];
    
    _STRUCT_MCONTEXT machineContext;
    // 获取线程的信息，如果失败则返回
    if(!doraemon_fillThreadStateIntoMachineContext(thread, &machineContext)) {
        return [NSString stringWithFormat:@"Fail to get information about thread: %u", thread];
    }
    
    // 获取当前正在执行的指令，并存储到堆栈中
    const uintptr_t instructionAddress = doraemon_mach_instructionAddress(&machineContext);
    backtraceBuffer[i] = instructionAddress;
    ++i;
    
    // 获取链接寄存器，并存储到堆栈中。这是某些架构中使用的特殊寄存器，用来保存函数调用的返回地址
    uintptr_t linkRegister = doraemon_mach_linkRegister(&machineContext);
    if (linkRegister) {
        backtraceBuffer[i] = linkRegister;
        i++;
    }
    
    // 如果没有成功获取当前指令地址则返回
    if(instructionAddress == 0) {
        return @"Fail to get instruction address";
    }
    
    // 初始化一个空的帧结构
    DoraemonStackFrameEntry frame = {0};
    // 获取当前帧
    const uintptr_t framePtr = doraemon_mach_framePointer(&machineContext);
    // 将当前帧内容复制到frame里。失败则报错返回
    if(framePtr == 0 ||
       doraemon_mach_copyMem((void *)framePtr, &frame, sizeof(frame)) != KERN_SUCCESS) {
        return @"Fail to get frame pointer";
    }
    
    for(; i < 50; i++) {
        // 将帧的返回地址存入
        backtraceBuffer[i] = frame.return_address;
        // 继续尝试去将前一帧的内容复制到frame里，如果失败则不再遍历
        if(backtraceBuffer[i] == 0 ||
           frame.previous == 0 ||
           doraemon_mach_copyMem(frame.previous, &frame, sizeof(frame)) != KERN_SUCCESS) {
            break;
        }
    }
    
    int backtraceLength = i;
    Dl_info symbolicated[backtraceLength];
    // 将保存的栈帧数组符号化后保存
    doraemon_symbolicate(backtraceBuffer, symbolicated, backtraceLength, 0);
    // 将符号化的数据转换为字符串并拼接
    for (int i = 0; i < backtraceLength; ++i) {
        [resultString appendFormat:@"%@", doraemon_logBacktraceEntry(i, backtraceBuffer[i], &symbolicated[i])];
    }
    [resultString appendFormat:@"\n"];
    // 最后返回拼接后的字符串
    return [resultString copy];
}

#pragma -mark Convert NSThread to Mach thread
// 转换mach thread到线程
thread_t doraemon_machThreadFromNSThread(NSThread *nsthread) {
    // 获取当前任务的线程
    char name[256];
    mach_msg_type_number_t count;
    thread_act_array_t list;
    task_threads(mach_task_self(), &list, &count);
    
    // 获取当前时间
    NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
    // 设置线程名称
    NSString *originName = [nsthread name];
    [nsthread setName:[NSString stringWithFormat:@"%f", currentTimestamp]];
    // 如果是主线就直接返回之前获取的mach thread
    if ([nsthread isMainThread]) {
        return (thread_t)main_thread_id;
    }
    
    // 遍历所有线程，这一段看得云里雾里⚠️
    for (int i = 0; i < count; ++i) {
        // 生成pthread_t对象
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        // 如果当前线程是主线程，且pthread对象为主线程对应的，则返回该对象
        if ([nsthread isMainThread]) {
            if (list[i] == main_thread_id) {
                return list[i];
            }
        }
        
        if (pt) {
            name[0] = '\0';
            pthread_getname_np(pt, name, sizeof name);
            // 如果线程名和pthread对象名相等，则找到了对应的对象，返回该对象
            if (!strcmp(name, [nsthread name].UTF8String)) {
                [nsthread setName:originName];
                return list[i];
            }
        }
    }
    // 恢复线程名字
    [nsthread setName:originName];
    return mach_thread_self();
}

#pragma -mark GenerateBacbsrackEnrty
// 将堆栈的一条记录格式化为字符串
NSString* doraemon_logBacktraceEntry(const int entryNum,
                               const uintptr_t address,
                               const Dl_info* const dlInfo) {
    char faddrBuff[20];
    char saddrBuff[20];
    // 处理库的名称
    const char* fname = doraemon_lastPathEntry(dlInfo->dli_fname);
    if(fname == NULL) {
        // 如果没有名称，则取基址作为名称
        sprintf(faddrBuff, Doraemon_POINTER_FMT, (uintptr_t)dlInfo->dli_fbase);
        fname = faddrBuff;
    }
    // 计算地址和最近的符号的偏移量
    uintptr_t offset = address - (uintptr_t)dlInfo->dli_saddr;
    // 获取最近的符号的名称
    const char* sname = dlInfo->dli_sname;
    if(sname == NULL) {
        // 如果没有则设置为最近的符号的地址
        sprintf(saddrBuff, Doraemon_POINTER_SHORT_FMT, (uintptr_t)dlInfo->dli_fbase);
        sname = saddrBuff;
        // 重新设置偏移量为地址和基址的距离
        offset = address - (uintptr_t)dlInfo->dli_fbase;
    }
    // 将这几个变量设置为一条记录
    return [NSString stringWithFormat:@"%-30s  0x%08" PRIxPTR " %s + %lu\n" ,fname, (uintptr_t)address, sname, offset];
}
// 返回最后一个路径分量，也就是最后一个/后面的字符串
const char* doraemon_lastPathEntry(const char* const path) {
    if(path == NULL) {
        return NULL;
    }
    
    // 寻找最后一个/出现的位置
    char* lastFile = strrchr(path, '/');
    // 如果找到了，则返回/后的第一位，否则返回整个path
    return lastFile == NULL ? path : lastFile + 1;
}

#pragma -mark HandleMachineContext
/// 获取线程状态信息
bool doraemon_fillThreadStateIntoMachineContext(thread_t thread, _STRUCT_MCONTEXT *machineContext) {
    // 声明变量去获取线程状态信息，并通过宏来获取该结构占用大小
    mach_msg_type_number_t state_count = Doraemon_THREAD_STATE_COUNT;
    // 获取线程状态信息，参数依次是指定线程对象、要检索的特定信息、信息要存储的位置、指向信息预期占用大小的指针
    kern_return_t kr = thread_get_state(thread, Doraemon_THREAD_STATE, (thread_state_t)&machineContext->__ss, &state_count);
    // 返回获取结果
    return (kr == KERN_SUCCESS);
}
/// 获取当前帧地址
uintptr_t doraemon_mach_framePointer(mcontext_t const machineContext){
    return machineContext->__ss.Doraemon_FRAME_POINTER;
}
/// 获取当前栈地址
uintptr_t doraemon_mach_stackPointer(mcontext_t const machineContext){
    return machineContext->__ss.Doraemon_STACK_POINTER;
}
/// 获取当前指令地址
uintptr_t doraemon_mach_instructionAddress(mcontext_t const machineContext){
    return machineContext->__ss.Doraemon_INSTRUCTION_ADDRESS;
}

uintptr_t doraemon_mach_linkRegister(mcontext_t const machineContext){
#if defined(__i386__) || defined(__x86_64__)
    return 0;
#else
    return machineContext->__ss.__lr;
#endif
}

/// 将指定数量的字节从一个区域复制到另一个区域
kern_return_t doraemon_mach_copyMem(const void *const src, void *const dst, const size_t numBytes){
    vm_size_t bytesCopied = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)src, (vm_size_t)numBytes, (vm_address_t)dst, &bytesCopied);
}

#pragma -mark Symbolicate
// 将栈帧符号化后保存在DL_info结构中
void doraemon_symbolicate(const uintptr_t* const backtraceBuffer,
                    Dl_info* const symbolsBuffer,
                    const int numEntries,
                    const int skippedEntries){
    /*
     backtraceBuffer里，第一个对象储存的是直接根据线程状态信息得到的指令地址，是从寄存器里直接拿的。
     第二个对象储存的是当前栈帧的返回地址，也就是前一帧的基地址，第三个对象储存的是上一个栈帧的返回地址，依此类推
     */
    int i = 0;
    // 如果不需要跳过入口的地址，则将入口地址符号化并保存
    if(!skippedEntries && i < numEntries) {
        // 因为是从寄存器直接拿的地址，因此不需要处理直接查询
        doraemon_dladdr(backtraceBuffer[i], &symbolsBuffer[i]);
        i++;
    }
    
    for(; i < numEntries; i++) {
        // 由于是从栈帧的返回地址里拿的地址，因此需要转换
        doraemon_dladdr(Doraemon_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(backtraceBuffer[i]), &symbolsBuffer[i]);
    }
}

// 查找给定地址的符号信息
bool doraemon_dladdr(const uintptr_t address, Dl_info* const info) {
    info->dli_fname = NULL;
    info->dli_fbase = NULL;
    info->dli_sname = NULL;
    info->dli_saddr = NULL;
    
    // 获取包含该地址的库的索引
    const uint32_t idx = doraemon_imageIndexContainingAddress(address);
    if(idx == UINT_MAX) {
        return false;
    }
    // 获取该库的header
    const struct mach_header* header = _dyld_get_image_header(idx);
    // 获取偏移量
    const uintptr_t imageVMAddrSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(idx);
    // 修正目标地址为偏移之前的地址
    const uintptr_t addressWithSlide = address - imageVMAddrSlide;
    // 获取库的__linkedit段基址并添加上偏移量
    const uintptr_t segmentBase = doraemon_segmentBaseOfImageIndex(idx) + imageVMAddrSlide;
    if(segmentBase == 0) {
        return false;
    }
    // 将库的名称和基址存入
    info->dli_fname = _dyld_get_image_name(idx);
    info->dli_fbase = (void*)header;
    
    // Find symbol tables and get whichever symbol is closest to the address.
    const Doraemon_NLIST* bestMatch = NULL;
    // 记录能找到的符号与目标地址最近的距离，后续用到
    uintptr_t bestDistance = ULONG_MAX;
    // 获取header里的第一个命令
    uintptr_t cmdPtr = doraemon_firstCmdAfterHeader(header);
    if(cmdPtr == 0) {
        return false;
    }
    // 遍历命令
    for(uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
        const struct load_command* loadCmd = (struct load_command*)cmdPtr;
        // 如果是当前库的符号表，则处理
        if(loadCmd->cmd == LC_SYMTAB) {
            // 获取符号表
            const struct symtab_command* symtabCmd = (struct symtab_command*)cmdPtr;
            const Doraemon_NLIST* symbolTable = (Doraemon_NLIST*)(segmentBase + symtabCmd->symoff);
            // 获取字符串表
            const uintptr_t stringTable = segmentBase + symtabCmd->stroff;
            // 遍历符号表
            for(uint32_t iSym = 0; iSym < symtabCmd->nsyms; iSym++) {
                // If n_value is 0, the symbol refers to an external object.
                // 如果是内部的符号才继续处理，否则跳过
                if(symbolTable[iSym].n_value != 0) {
                    // 获取符号基址
                    uintptr_t symbolBase = symbolTable[iSym].n_value;
                    // 获取目标地址与符号基址的距离
                    uintptr_t currentDistance = addressWithSlide - symbolBase;
                    // 如果地址在该符号之后，且距离比之前记录的距离要小，则更新距离并记录
                    if((addressWithSlide >= symbolBase) &&
                       (currentDistance <= bestDistance)) {
                        // 记录最吻合的符号
                        bestMatch = symbolTable + iSym;
                        // 记录最小距离
                        bestDistance = currentDistance;
                    }
                }
            }
            // 如果有最吻合的符号则处理
            if(bestMatch != NULL) {
                // 记录符号地址（包含偏移量）
                info->dli_saddr = (void*)(bestMatch->n_value + imageVMAddrSlide);
                // 记录符号名称
                info->dli_sname = (char*)((intptr_t)stringTable + (intptr_t)bestMatch->n_un.n_strx);
                // 处理符号名为下划线的情况，这种一般是隐藏符号
                if(*info->dli_sname == '_') {
                    info->dli_sname++;
                }
                // This happens if all symbols have been stripped.
                // 如果所有符号都是被stripped的状态，则地址会和基址一样，且最吻合的符号的n_type为3，这种情况下将符号名称去除（不是特别明白⚠️）
                if(info->dli_saddr == info->dli_fbase && bestMatch->n_type == 3) {
                    info->dli_sname = NULL;
                }
                break;
            }
        }
        cmdPtr += loadCmd->cmdsize;
    }
    return true;
}

/// 返回mach header里的第一个命令
uintptr_t doraemon_firstCmdAfterHeader(const struct mach_header* const header) {
    switch(header->magic) {
        case MH_MAGIC:
        case MH_CIGAM:
            return (uintptr_t)(header + 1);
        case MH_MAGIC_64:
        case MH_CIGAM_64:
            return (uintptr_t)(((struct mach_header_64*)header) + 1);
        default:
            return 0;  // Header is corrupt
    }
}

// 查找包含给定的内存地址的macho文件
uint32_t doraemon_imageIndexContainingAddress(const uintptr_t address) {
    // 获取镜像数量
    const uint32_t imageCount = _dyld_image_count();
    const struct mach_header* header = 0;
    // 遍历镜像
    for(uint32_t iImg = 0; iImg < imageCount; iImg++) {
        // 获取镜像header
        header = _dyld_get_image_header(iImg);
        if(header != NULL) {
            // Look for a segment command with this address within its range.
            // 获取地址偏移量并调整要查找的目标内存地址
            uintptr_t addressWSlide = address - (uintptr_t)_dyld_get_image_vmaddr_slide(iImg);
            // 获取第一个命令，为后续遍历做准备
            uintptr_t cmdPtr = doraemon_firstCmdAfterHeader(header);
            if(cmdPtr == 0) {
                continue;
            }
            // 遍历命令
            for(uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
                const struct load_command* loadCmd = (struct load_command*)cmdPtr;
                // 如果是segmentCommand则转换并判定是否在范围
                if(loadCmd->cmd == LC_SEGMENT) {
                    const struct segment_command* segCmd = (struct segment_command*)cmdPtr;
                    // 如果目标地址在当前segmentCommand范围内，则返回镜像索引
                    if(addressWSlide >= segCmd->vmaddr &&
                       addressWSlide < segCmd->vmaddr + segCmd->vmsize) {
                        return iImg;
                    }
                }
                // 如果是64位的segmentCommand则转换并判定是否在范围
                else if(loadCmd->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64* segCmd = (struct segment_command_64*)cmdPtr;
                    // 如果目标地址在当前segmentCommand范围内，则返回镜像索引
                    if(addressWSlide >= segCmd->vmaddr &&
                       addressWSlide < segCmd->vmaddr + segCmd->vmsize) {
                        return iImg;
                    }
                }
                cmdPtr += loadCmd->cmdsize;
            }
        }
    }
    return UINT_MAX;
}

// 寻找__LINKEDIT段的基址
uintptr_t doraemon_segmentBaseOfImageIndex(const uint32_t idx) {
    // 获取header
    const struct mach_header* header = _dyld_get_image_header(idx);
    
    // Look for a segment command and return the file image address.
    // 获取第一个命令
    uintptr_t cmdPtr = doraemon_firstCmdAfterHeader(header);
    if(cmdPtr == 0) {
        return 0;
    }
    // 遍历命令，寻找到SEG_LINKEDIT，也就是__LINKEDIT段，该区域包含了函数名称、地址等，并返回该区域的基址
    for(uint32_t i = 0;i < header->ncmds; i++) {
        const struct load_command* loadCmd = (struct load_command*)cmdPtr;
        if(loadCmd->cmd == LC_SEGMENT) {
            const struct segment_command* segmentCmd = (struct segment_command*)cmdPtr;
            if(strcmp(segmentCmd->segname, SEG_LINKEDIT) == 0) {
                return segmentCmd->vmaddr - segmentCmd->fileoff;
            }
        }
        else if(loadCmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* segmentCmd = (struct segment_command_64*)cmdPtr;
            if(strcmp(segmentCmd->segname, SEG_LINKEDIT) == 0) {
                return (uintptr_t)(segmentCmd->vmaddr - segmentCmd->fileoff);
            }
        }
        cmdPtr += loadCmd->cmdsize;
    }
    return 0;
}

@end
