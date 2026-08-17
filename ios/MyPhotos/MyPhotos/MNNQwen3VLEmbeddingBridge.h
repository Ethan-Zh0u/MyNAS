#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C++ boundary around the pinned MNN runtime. The object is
/// intentionally used only from one serial worker queue by its Swift owner.
/// It never receives PhotoKit objects and never persists image input.
@interface MNNQwen3VLEmbeddingBridge : NSObject

+ (BOOL)isRuntimeAvailable;

- (nullable instancetype)initWithModelDirectoryURL:(NSURL *)modelDirectoryURL
                                             error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (nullable NSArray<NSNumber *> *)embedText:(NSString *)text
                                       error:(NSError * _Nullable * _Nullable)error;

/// The JPEG is written under the app's temporary directory only while MNN
/// reads it, then deleted before this method returns.
- (nullable NSArray<NSNumber *> *)embedJPEGData:(NSData *)jpegData
                                          error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
