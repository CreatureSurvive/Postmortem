#import <Foundation/Foundation.h>
#import <MetricKit/MetricKit.h>
#import <objc/runtime.h>

@interface NSObject (PFrame) - (instancetype)initWithBinaryName:(NSString *)n binaryUUID:(NSUUID *)u address:(NSNumber *)a binaryOffset:(NSNumber *)o sampleCount:(NSNumber *)c withDepth:(unsigned long long)d subFrameArray:(NSArray *)s; - (instancetype)initWithTopCallStackFrames:(NSArray *)f isAttributedThread:(BOOL)a; @end
@interface MXCallStackTree (P) - (instancetype)initWithThreadArray:(NSArray *)a aggregatedByProcess:(BOOL)b; @end
@interface MXMetaData (P) - (instancetype)initWithRegionFormat:(NSString *)r osVersion:(NSString *)o deviceType:(NSString *)d appBuildVersion:(NSString *)b platformArchitecture:(NSString *)p bundleID:(NSString *)bid pid:(int)pid isTestFlightApp:(BOOL)tf; @end
@interface MXCrashDiagnostic (P) - (instancetype)initWithMetaData:(id)m applicationVersion:(NSString *)v signpostData:(id)s pid:(int)pid terminationReason:(NSString *)t applicationSpecificInfo:(NSString *)i virtualMemoryRegionInfo:(NSString *)vm exceptionType:(NSNumber *)et exceptionCode:(NSNumber *)ec exceptionReason:(id)er signal:(NSNumber *)sig stackTrace:(id)st; @end
@interface MXHangDiagnostic (P) - (instancetype)initWithMetaData:(id)m applicationVersion:(NSString *)v signpostData:(id)s pid:(int)pid callStack:(id)cs hangDuration:(NSMeasurement *)d; @end
@interface MXCPUExceptionDiagnostic (P) - (instancetype)initWithMetaData:(id)m applicationVersion:(NSString *)v signpostData:(id)s pid:(int)pid callStack:(id)cs totalCpuTime:(NSMeasurement *)c totalSampledTime:(NSMeasurement *)t; @end
@interface MXDiskWriteExceptionDiagnostic (P) - (instancetype)initWithMetaData:(id)m applicationVersion:(NSString *)v signpostData:(id)s pid:(int)pid totalWritesCaused:(NSMeasurement *)w stackTrace:(id)st; @end
@interface NSObject (PLaunch) - (instancetype)initWithMetaData:(id)m applicationVersion:(NSString *)v signpostData:(id)s pid:(int)pid callStack:(id)cs launchDuration:(NSMeasurement *)d; @end
@interface MXCrashDiagnosticObjectiveCExceptionReason (P) - (instancetype)initWithComposedMessage:(NSString *)m formatString:(NSString *)f arguments:(NSArray *)a type:(NSString *)t className:(NSString *)c exceptionName:(NSString *)n; @end
@interface MXDiagnosticPayload (P) - (instancetype)initWithTimeStampBegin:(NSDate *)b withTimeStampEnd:(NSDate *)e withDiagnostics:(NSArray *)d; @end

int main(int argc, char **argv) {
  @autoreleasepool {
    [MXMetricManager sharedManager];
    id f2 = [[NSClassFromString(@"MXCallStackFrame") alloc] initWithBinaryName:@"Demo" binaryUUID:[[NSUUID alloc] initWithUUIDString:@"70B89F27-1634-3580-A695-57CDB41D7743"] address:@4295000000 binaryOffset:@5000 sampleCount:@1 withDepth:1 subFrameArray:nil];
    id f1 = [[NSClassFromString(@"MXCallStackFrame") alloc] initWithBinaryName:@"libswiftCore.dylib" binaryUUID:[[NSUUID alloc] initWithUUIDString:@"9A0E4C3F-1B6B-3D6E-8A7B-2E3C4D5E6F70"] address:@7000000000 binaryOffset:@123456 sampleCount:@1 withDepth:0 subFrameArray:@[f2]];
    id f3 = [[NSClassFromString(@"MXCallStackFrame") alloc] initWithBinaryName:@"libsystem_kernel.dylib" binaryUUID:[[NSUUID alloc] initWithUUIDString:@"11111111-2222-3333-4444-555555555555"] address:@7100000000 binaryOffset:@777 sampleCount:@3 withDepth:0 subFrameArray:nil];
    NSArray *threads = @[[[NSClassFromString(@"MXCallStackThread") alloc] initWithTopCallStackFrames:@[f1] isAttributedThread:YES], [[NSClassFromString(@"MXCallStackThread") alloc] initWithTopCallStackFrames:@[f3] isAttributedThread:NO]];
    MXCallStackTree *tree = [[MXCallStackTree alloc] initWithThreadArray:threads aggregatedByProcess:NO];
    NSLog(@"tree: %@", [[NSString alloc] initWithData:[tree JSONRepresentation] encoding:NSUTF8StringEncoding]);
    MXMetaData *meta = [[MXMetaData alloc] initWithRegionFormat:@"US" osVersion:@"iPhone OS 18.2 (22C152)" deviceType:@"iPhone16,1" appBuildVersion:@"42" platformArchitecture:@"arm64e" bundleID:@"com.example.demo" pid:1234 isTestFlightApp:YES];
    MXCrashDiagnosticObjectiveCExceptionReason *reason = [[MXCrashDiagnosticObjectiveCExceptionReason alloc] initWithComposedMessage:@"*** -[__NSArrayM objectAtIndex:]: index 5 beyond bounds [0 .. 2]" formatString:@"*** -[__NSArrayM objectAtIndex:]: index %lu beyond bounds [0 .. %lu]" arguments:@[@"5", @"2"] type:@"NSException" className:@"__NSArrayM" exceptionName:@"NSRangeException"];
    MXCrashDiagnostic *crash = [[MXCrashDiagnostic alloc] initWithMetaData:meta applicationVersion:@"1.2.0" signpostData:nil pid:1234 terminationReason:@"Namespace SIGNAL, Code 5 Trace/BPT trap: 5" applicationSpecificInfo:nil virtualMemoryRegionInfo:@"0 is not in any region." exceptionType:@6 exceptionCode:@1 exceptionReason:reason signal:@5 stackTrace:tree];
    NSMeasurement *hangDur = [[NSMeasurement alloc] initWithDoubleValue:3.5 unit:NSUnitDuration.seconds];
    MXHangDiagnostic *hang = [[MXHangDiagnostic alloc] initWithMetaData:meta applicationVersion:@"1.2.0" signpostData:nil pid:1234 callStack:tree hangDuration:hangDur];
    MXCPUExceptionDiagnostic *cpu = [[MXCPUExceptionDiagnostic alloc] initWithMetaData:meta applicationVersion:@"1.2.0" signpostData:nil pid:1234 callStack:tree totalCpuTime:[[NSMeasurement alloc] initWithDoubleValue:90 unit:NSUnitDuration.seconds] totalSampledTime:[[NSMeasurement alloc] initWithDoubleValue:180 unit:NSUnitDuration.seconds]];
    MXDiskWriteExceptionDiagnostic *disk = [[MXDiskWriteExceptionDiagnostic alloc] initWithMetaData:meta applicationVersion:@"1.2.0" signpostData:nil pid:1234 totalWritesCaused:[[NSMeasurement alloc] initWithDoubleValue:2147483648 unit:NSUnitInformationStorage.bytes] stackTrace:tree];
    id launch = [[NSClassFromString(@"MXAppLaunchDiagnostic") alloc] initWithMetaData:meta applicationVersion:@"1.2.0" signpostData:nil pid:1234 callStack:tree launchDuration:[[NSMeasurement alloc] initWithDoubleValue:2500 unit:NSUnitDuration.milliseconds]];
    NSDate *b = [NSDate dateWithTimeIntervalSince1970:1790000000];
    MXDiagnosticPayload *payload = [[MXDiagnosticPayload alloc] initWithTimeStampBegin:b withTimeStampEnd:[b dateByAddingTimeInterval:86400] withDiagnostics:(id)@{@"crashDiagnostics": @[crash], @"hangDiagnostics": @[hang], @"cpuExceptionDiagnostics": @[cpu], @"diskWriteExceptionDiagnostics": @[disk], @"appLaunchDiagnostics": launch ? @[launch] : @[]}];
    NSData *json = [payload JSONRepresentation];
    [json writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
    printf("%s\n", [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
  }
}
