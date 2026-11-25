#import "PhotoKitImporter.h"
#import <Photos/Photos.h>
#import <sys/stat.h>

@interface PHPhotoLibrary (PathImport)
+ (void)enableMultiLibraryMode;
- (instancetype)initWithPhotoLibraryURL:(NSURL *)url type:(NSInteger)type;
- (NSURL *)photoLibraryURL;
@end

static NSString *const ImportErrorDomain = @"iPhoneAlbumSync.PhotoKit";

static NSArray *Fail(NSError **error, NSInteger code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:ImportErrorDomain code:code
                                  userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return nil;
}

static BOOL DatabaseMatches(NSURL *library, NSDictionary *request) {
    NSURL *database = [library URLByAppendingPathComponent:@"database/Photos.sqlite"];
    struct stat info;
    return stat(database.fileSystemRepresentation, &info) == 0
        && info.st_dev == [request[@"device"] longLongValue]
        && info.st_ino == [request[@"inode"] unsignedLongLongValue];
}

NSArray<NSString *> *ImportWithPhotoKit(NSDictionary *request, NSError **error) {
    NSString *path = request[@"library"];
    NSArray<NSDictionary *> *items = request[@"items"];
    if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]
        || ![path.pathExtension isEqualToString:@"photoslibrary"]
        || ![items isKindOfClass:NSArray.class] || items.count == 0 || items.count > 150) {
        return Fail(error, 1, @"导入请求无效。");
    }
    NSURL *target = [NSURL fileURLWithPath:path isDirectory:YES].URLByResolvingSymlinksInPath;
    if (!DatabaseMatches(target, request)) {
        return Fail(error, 2, @"目标图库已移动或被替换，本次未提交导入。");
    }
    for (NSDictionary *item in items) {
        if (![[NSFileManager defaultManager] isReadableFileAtPath:item[@"primary"]]
            || (item[@"companion"] && ![[NSFileManager defaultManager] isReadableFileAtPath:item[@"companion"]])) {
            return Fail(error, 1, @"暂存原片或实况配对视频无法读取。");
        }
    }
    Class libraryClass = PHPhotoLibrary.class;
    if (![libraryClass respondsToSelector:@selector(enableMultiLibraryMode)]
        || ![libraryClass instancesRespondToSelector:@selector(initWithPhotoLibraryURL:type:)]
        || ![libraryClass instancesRespondToSelector:@selector(photoLibraryURL)]) {
        return Fail(error, 3, @"此 macOS 版本不支持按路径后台写入图库。");
    }
    __block PHAuthorizationStatus authorization = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (authorization == PHAuthorizationStatusNotDetermined) {
        dispatch_semaphore_t received = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
                authorization = status;
                dispatch_semaphore_signal(received);
            }];
        });
        if (dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC)) != 0) {
            return Fail(error, 4, @"等待照片添加授权超时，请确认权限后重试。");
        }
    }
    if (authorization != PHAuthorizationStatusAuthorized) {
        return Fail(error, 4, @"请在「系统设置 → 隐私与安全性 → 照片」允许此 App 添加照片。");
    }

    static dispatch_once_t multiLibraryMode;
    dispatch_once(&multiLibraryMode, ^{
        [PHPhotoLibrary enableMultiLibraryMode];
    });
    PHPhotoLibrary *library = [[PHPhotoLibrary alloc] initWithPhotoLibraryURL:target type:0];
    NSURL *actual = library.photoLibraryURL.URLByResolvingSymlinksInPath;
    if (![actual.path isEqualToString:target.path] || !DatabaseMatches(target, request)) {
        return Fail(error, 2, @"PhotoKit 未能确认指定图库，本次未提交导入。");
    }
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:items.count];
    BOOL success = [library performChangesAndWait:^{
        for (NSDictionary *item in items) {
            PHAssetCreationRequest *asset = [PHAssetCreationRequest creationRequestForAsset];
            asset.creationDate = [NSDate dateWithTimeIntervalSinceReferenceDate:[item[@"capture"] doubleValue]];
            PHAssetResourceType type = [item[@"kind"] integerValue] == 1 ? PHAssetResourceTypeVideo : PHAssetResourceTypePhoto;
            [asset addResourceWithType:type fileURL:[NSURL fileURLWithPath:item[@"primary"]] options:nil];
            if (item[@"companion"]) {
                [asset addResourceWithType:PHAssetResourceTypePairedVideo
                                   fileURL:[NSURL fileURLWithPath:item[@"companion"]] options:nil];
            }
            NSString *identifier = asset.placeholderForCreatedAsset.localIdentifier;
            [identifiers addObject:identifier ?: @""];
        }
    } error:error];
    return success ? identifiers : nil;
}
