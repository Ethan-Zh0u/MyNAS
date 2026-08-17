#import "MNNQwen3VLEmbeddingBridge.h"

#if defined(MYPHOTOS_ENABLE_MNN_RUNTIME) && __has_include(<MNN/llm/llm.hpp>)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#import <MNN/llm/llm.hpp>
#pragma clang diagnostic pop
#define MYPHOTOS_HAS_MNN_QWEN_RUNTIME 1
#elif defined(MYPHOTOS_ENABLE_MNN_RUNTIME) && __has_include(<llm/llm.hpp>)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#import <llm/llm.hpp>
#pragma clang diagnostic pop
#define MYPHOTOS_HAS_MNN_QWEN_RUNTIME 1
#else
#define MYPHOTOS_HAS_MNN_QWEN_RUNTIME 0
#endif

#if MYPHOTOS_HAS_MNN_QWEN_RUNTIME
#include <cmath>
#include <memory>
#include <string>

using namespace MNN::Transformer;
#endif

namespace {

NSString * const MNNQwen3VLEmbeddingBridgeErrorDomain = @"com.ethanzhou.MyPhotos.MNNQwen3VLEmbedding";

enum MNNQwen3VLEmbeddingBridgeErrorCode {
    MNNQwen3VLEmbeddingBridgeErrorCodeInvalidModelDirectory = 1,
    MNNQwen3VLEmbeddingBridgeErrorCodeModelLoadFailed = 2,
    MNNQwen3VLEmbeddingBridgeErrorCodeInvalidInput = 3,
    MNNQwen3VLEmbeddingBridgeErrorCodeInferenceFailed = 4,
    MNNQwen3VLEmbeddingBridgeErrorCodeRuntimeUnavailable = 5,
};

void SetBridgeError(
    NSError * _Nullable * _Nullable error,
    MNNQwen3VLEmbeddingBridgeErrorCode code,
    NSString *description
) {
    if (error != nil) {
        *error = [NSError errorWithDomain:MNNQwen3VLEmbeddingBridgeErrorDomain
                                     code:code
                                 userInfo:@{ NSLocalizedDescriptionKey: description }];
    }
}

#if MYPHOTOS_HAS_MNN_QWEN_RUNTIME
std::string UTF8String(NSString *value) {
    const char *raw = value.UTF8String;
    return raw == nullptr ? std::string() : std::string(raw);
}
#endif

} // namespace

@implementation MNNQwen3VLEmbeddingBridge {
#if MYPHOTOS_HAS_MNN_QWEN_RUNTIME
    std::shared_ptr<Embedding> _embedding;
#endif
}

+ (BOOL)isRuntimeAvailable {
    return MYPHOTOS_HAS_MNN_QWEN_RUNTIME;
}

- (nullable instancetype)initWithModelDirectoryURL:(NSURL *)modelDirectoryURL
                                             error:(NSError * _Nullable * _Nullable)error {
#if !MYPHOTOS_HAS_MNN_QWEN_RUNTIME
    SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeRuntimeUnavailable, @"本地语义运行时尚未随 App 安装。");
    return nil;
#else
    self = [super init];
    if (self == nil) {
        return nil;
    }

    NSNumber *isDirectory = nil;
    if (![modelDirectoryURL getResourceValue:&isDirectory
                                      forKey:NSURLIsDirectoryKey
                                       error:nil] || !isDirectory.boolValue) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeInvalidModelDirectory, @"本地语义模型目录不可用。");
        return nil;
    }
    NSURL *configURL = [modelDirectoryURL URLByAppendingPathComponent:@"config.json" isDirectory:NO];
    if (![[NSFileManager defaultManager] fileExistsAtPath:configURL.path]) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeInvalidModelDirectory, @"本地语义模型缺少配置文件。");
        return nil;
    }

    const std::string configPath = UTF8String(configURL.path);
    _embedding.reset(Embedding::createEmbedding(configPath, false));
    if (_embedding == nullptr) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeModelLoadFailed, @"无法创建本地语义模型。");
        return nil;
    }

    NSURL *temporaryDirectory = [[NSFileManager defaultManager].temporaryDirectory
        URLByAppendingPathComponent:@"mnn-qwen3-vl-embedding" isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:temporaryDirectory
                                   withIntermediateDirectories:YES
                                                    attributes:@{ NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication }
                                                         error:&directoryError]) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeModelLoadFailed, directoryError.localizedDescription);
        return nil;
    }
    const std::string temporaryPath = UTF8String(temporaryDirectory.path);
    _embedding->set_config(
        "{\"tmp_path\":\"" + temporaryPath
        + "\",\"use_mmap\":true,\"backend_type\":\"cpu\",\"thread_num\":4,\"mllm\":{\"backend_type\":\"cpu\",\"thread_num\":4}}"
    );
    if (!_embedding->load()) {
        _embedding.reset();
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeModelLoadFailed, @"无法加载本地语义模型。");
        return nil;
    }
    return self;
#endif
}

- (nullable NSArray<NSNumber *> *)embedText:(NSString *)text
                                       error:(NSError * _Nullable * _Nullable)error {
#if !MYPHOTOS_HAS_MNN_QWEN_RUNTIME
    SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeRuntimeUnavailable, @"本地语义运行时尚未随 App 安装。");
    return nil;
#else
    if (text.length == 0) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeInvalidInput, @"语义查询不能为空。");
        return nil;
    }
    return [self embeddingForPrompt:UTF8String(text) error:error];
#endif
}

- (nullable NSArray<NSNumber *> *)embedJPEGData:(NSData *)jpegData
                                          error:(NSError * _Nullable * _Nullable)error {
#if !MYPHOTOS_HAS_MNN_QWEN_RUNTIME
    SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeRuntimeUnavailable, @"本地语义运行时尚未随 App 安装。");
    return nil;
#else
    if (jpegData.length == 0) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeInvalidInput, @"语义图片数据为空。");
        return nil;
    }

    NSURL *temporaryDirectory = [[NSFileManager defaultManager].temporaryDirectory
        URLByAppendingPathComponent:@"mnn-qwen3-vl-embedding" isDirectory:YES];
    NSURL *imageURL = [temporaryDirectory
        URLByAppendingPathComponent:[[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"jpeg"]
                   isDirectory:NO];
    NSError *writeError = nil;
    if (![jpegData writeToURL:imageURL options:NSDataWritingAtomic error:&writeError]) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeInvalidInput, writeError.localizedDescription);
        return nil;
    }

    NSArray<NSNumber *> *result = nil;
    @try {
        const std::string prompt = "<img>" + UTF8String(imageURL.path) + "</img>";
        result = [self embeddingForPrompt:prompt error:error];
    } @finally {
        [[NSFileManager defaultManager] removeItemAtURL:imageURL error:nil];
    }
    return result;
#endif
}

#if MYPHOTOS_HAS_MNN_QWEN_RUNTIME
- (nullable NSArray<NSNumber *> *)embeddingForPrompt:(const std::string &)prompt
                                                 error:(NSError * _Nullable * _Nullable)error {
    if (_embedding == nullptr) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeModelLoadFailed, @"本地语义模型尚未加载。");
        return nil;
    }

    auto output = _embedding->txt_embedding(prompt);
    if (output == nullptr || output->getInfo() == nullptr) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeInferenceFailed, @"本地语义模型未返回向量。");
        return nil;
    }
    const auto *values = output->readMap<float>();
    const size_t dimension = output->getInfo()->size;
    if (values == nullptr || dimension != 2048) {
        SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeInferenceFailed, @"本地语义模型返回了无效维度的向量。");
        return nil;
    }

    NSMutableArray<NSNumber *> *vector = [NSMutableArray arrayWithCapacity:dimension];
    for (size_t index = 0; index < dimension; index += 1) {
        if (!std::isfinite(values[index])) {
            SetBridgeError(error, MNNQwen3VLEmbeddingBridgeErrorCodeInferenceFailed, @"本地语义模型返回了无效向量。");
            return nil;
        }
        [vector addObject:@(values[index])];
    }
    return vector;
}
#endif

@end
