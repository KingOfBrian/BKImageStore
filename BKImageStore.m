//
//  ShotLoader.m
//  lifelapse
//
//  Created by Brian King on 2/7/11.
//  Copyright 2011 King Software Design. All rights reserved.
//

#import "Shot.h"
#import "BKImageStore.h"

static dispatch_queue_t __image_store_background_queue;

dispatch_queue_t image_store_background_queue()
{
    if (__image_store_background_queue == NULL)
    {
        __image_store_background_queue = dispatch_queue_create("com.ksd.image_store.background", 0);
    }
    return __image_store_background_queue;
}

static NSUInteger __loaderCount = 0;

#define CACHE_KEY(imageID, maxSize) [imageID stringByAppendingFormat:@"_%d", maxSize]

@interface BKImageStoreLoader : NSObject {
    NSUInteger _maxSize;
    bk_image_block _block;
    id _loaderID;
    BOOL _cancel;
}
- (id)initWithImageID:(NSString *)imageID size:(NSUInteger)maxSize block:(bk_image_block)block;

@property (readonly) NSString *imageID;
@property (readonly) id loaderID;
@property (readonly) NSUInteger maxSize;
@property (readonly) bk_image_block block;
@property (assign) BOOL cancel;
@end

@implementation BKImageStoreLoader
@synthesize imageID = _imageID;
@synthesize loaderID = _loaderID;
@synthesize maxSize = _maxSize;
@synthesize block = _block;
@synthesize cancel = cancel;
- (id)initWithImageID:(NSString *)imageID size:(NSUInteger)maxSize block:(bk_image_block)block;
{
    self = [super init];
    if (self)
    {
        _maxSize = maxSize;
        _block = [block copy];
        _imageID = [imageID copy];
        _loaderID = [[NSString stringWithFormat:@"ImageLoader-%d", __loaderCount++] retain];
        _cancel = NO;
    }
    return self;
}
- (NSString *)cacheKey
{
    return CACHE_KEY(_imageID, _maxSize);
}

- (void)dealloc
{
    [_block release];
    [_loaderID release];
    [_imageID release];
    [super dealloc];
}
@end

static BKImageStore *__imageStore = nil;

@implementation BKImageStore

@synthesize thumbnailSize = thumbnailSize_;
@synthesize storageSize = storageSize_;
@synthesize cacheFileIOErrorHandler = cacheFileIOErrorHandler_;
@synthesize jpegCompressionRatio = jpegCompressionRatio_;

+ (BKImageStore *)sharedStore
{
    if (__imageStore == nil)
    {
        __imageStore = [[BKImageStore alloc] init];
    }
    return __imageStore;
}

- (id)init
{
    self = [super init];
    if (self)
    {
        cache_ = [[NSCache alloc] init];
        imageBlockEntries_ = [[NSMutableDictionary alloc] init];
        cachedFileSizes_ = [[NSMutableSet alloc] init];
        thumbnailSize_ = NSNotFound;
        storageSize_ = NSNotFound;
        jpegCompressionRatio_ = 0.65;
        cacheFileIOErrorHandler_ = [^(NSError *error) {
            NSLog(@"Error saving a file to cache - %@", error);
        } copy];
    }
    return self;
}
- (void)dealloc
{
    [cache_ release];
    [imageBlockEntries_ release];
    [cacheFileIOErrorHandler_ release];
    [cachedFileSizes_ release];
    [super dealloc];
}

- (BOOL)preloadThumbnails
{
    return thumbnailSize_ != NSNotFound;
}

- (void)addCachedFileSize:(NSUInteger)size
{
    [cachedFileSizes_ addObject:[NSNumber numberWithUnsignedInteger:size]];
}
#pragma mark -
#pragma mark Path Accessors
- (NSString *)thumbnailPathForImageID:(NSString *)imageID
{
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    return [[[documents stringByAppendingPathComponent:@"Thumbnails"]
             stringByAppendingPathComponent:imageID] stringByAppendingPathExtension:@"jpg"];

}
- (NSString *)cachedPathForKey:(NSString *)key
{
    return [[[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject] stringByAppendingPathComponent:key] stringByAppendingPathExtension:@"jpg"];
}

- (BOOL)cachedFileExistsForKey:(NSString *)key
{
    return [[NSFileManager defaultManager] fileExistsAtPath:[self cachedPathForKey:key]];
}

- (NSString *)sourcePathForImageID:(NSString *)imageID
{
    return [[[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject] stringByAppendingPathComponent:imageID] stringByAppendingPathExtension:@"jpg"];
}

- (BOOL)sourceFileExistsForImageID:(NSString *)imageID
{
    return [[NSFileManager defaultManager] fileExistsAtPath:[self sourcePathForImageID:imageID]];
}

#pragma mark -
#pragma mark Image Cache
- (UIImage *)cacheImageForKey:(NSString *)key
{
    return [cache_ objectForKey:key];
}
- (void)cacheImage:(UIImage *)image forKey:(NSString *)key
{
    [cache_ setObject:image forKey:key];
}

#pragma mark Image Entry Creation
- (BKImageStoreLoader *)loaderForBlock:(bk_image_block)block imageID:(NSString *)imageID sized:(NSUInteger)maxSize 
{
    NSParameterAssert(block);
    NSParameterAssert(imageID);

    BKImageStoreLoader *loader = [[BKImageStoreLoader alloc] initWithImageID:imageID size:maxSize block:block];

    NSMutableDictionary *entries = [imageBlockEntries_ objectForKey:imageID];
    if (entries == nil)
    {
        entries = [NSMutableDictionary dictionary];
        [imageBlockEntries_ setObject:entries forKey:imageID];
    }
    [entries setObject:loader forKey:loader.loaderID];

    [loader release];
    return loader;
}

- (void)removeAllImageBlocksForImageID:(NSString *)imageID
{
    NSParameterAssert(imageID);
    for (BKImageStoreLoader *loader in [imageBlockEntries_ objectForKey:imageID])
        loader.cancel = YES;
    
    [imageBlockEntries_ removeObjectForKey:imageID];
}
- (void)removeImageBlockID:(id)loaderID forImageID:(NSString *)imageID;
{
    NSParameterAssert(imageID);
    // loaderID will be nil for cache hits
    if (loaderID == nil)
        return;
    
    NSMutableDictionary *entries = [imageBlockEntries_ objectForKey:imageID];
    BKImageStoreLoader *loader = [entries objectForKey:loaderID];
    loader.cancel = YES;
    [entries removeObjectForKey:loaderID];
    
    if ([entries count] == 0)
        [imageBlockEntries_ removeObjectForKey:imageID];

}
- (void)executeThumbnailForLoader:(BKImageStoreLoader *)loader
{
    UIImage *thumbnail = [self cacheImageForKey:CACHE_KEY(loader.imageID, self.thumbnailSize)];

    if (thumbnail)
        loader.block(thumbnail);
    else
        NSLog(@"No Thumbnail for imageID: %@", loader.imageID);
}
- (void)executeLoader:(BKImageStoreLoader *)loader withImage:(UIImage *)cachedImage;
{
    NSParameterAssert(loader);
    NSParameterAssert(cachedImage);
    //
    // Decompress the image off thread
    //
    UIGraphicsBeginImageContext(CGSizeMake(1, 1));
    [cachedImage drawAtPoint:CGPointZero];
    UIGraphicsEndImageContext();

    //
    // Execute the loader on the main thread and remove the loader
    //
    dispatch_async(dispatch_get_main_queue(), ^{
        //
        // If the loader has been cancelled, bail
        //
        if (loader.cancel)
            return;

        loader.block(cachedImage);
        
        NSMutableDictionary *entries = [imageBlockEntries_ objectForKey:loader.imageID];
        [entries removeObjectForKey:[loader loaderID]];
    });
}
- (BOOL)saveImageData:(NSData *)imageData toPath:(NSString *)path error:(NSError **)error
{
    NSString *directory = [path stringByDeletingLastPathComponent];
    
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                        withIntermediateDirectories:YES
                                                         attributes:nil 
                                                              error:error];
    
    if (ok)
        ok = [imageData writeToFile:path options:NSDataWritingAtomic error:error];
    
    return ok;
}

- (void)saveToFile:(NSString *)path image:(UIImage *)image
{
    NSParameterAssert(path);
    NSParameterAssert(image);
    
    dispatch_async(image_store_background_queue(), ^{
        NSData *imageData = UIImageJPEGRepresentation(image, jpegCompressionRatio_);
        NSError *error = nil;
        
        BOOL ok = [self saveImageData:imageData toPath:path error:&error];
        if (!ok)
        {
            self.cacheFileIOErrorHandler(error);
        }
    });
}
- (UIImage *)imageFromCacheFile:(NSString *)path
{
    CFURLRef pathURL = (CFURLRef)[NSURL fileURLWithPath:path];
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL(pathURL, NULL);
    
    CGImageRef imageRef = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
    UIImage *image = [[UIImage alloc] initWithCGImage:imageRef];

    CGImageRelease(imageRef);
    return [image autorelease];
}
- (void)loadFromCacheFile:(BKImageStoreLoader *)loader
{
    NSParameterAssert(loader);
    
    dispatch_async(image_store_background_queue(), ^{
        //
        // Bail if we no longer have an image_block for this ID
        //
        if (loader.cancel) return;
        
        //
        // Load the resized image from disk
        //
        UIImage *image = [self imageFromCacheFile:[self cachedPathForKey:[loader cacheKey]]];
        //
        // Cache the image and execute any pending blocks
        //
        [self cacheImage:image forKey:[loader cacheKey]];
        [self executeLoader:loader withImage:image];
    });
}
- (CFDictionaryRef)resizeOptionsForMaxSize:(NSUInteger)maxSize
{
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailWithTransform,
                             (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageIfAbsent,
                             (id)[NSNumber numberWithInt:maxSize], (id)kCGImageSourceThumbnailMaxPixelSize, 
                             nil];
    return (CFDictionaryRef)options;
}

- (void)generateThumbnailFromImageSource:(CGImageSourceRef)imageSource forImageID:(NSString *)imageID
{
    NSParameterAssert(imageSource);
    NSParameterAssert(imageID);
    NSParameterAssert([self preloadThumbnails]);
    
    CGImageRef thumbnailImageRef = 
        CGImageSourceCreateThumbnailAtIndex(imageSource,
                                            0, 
                                            [self resizeOptionsForMaxSize:self.thumbnailSize]);
    UIImage *thumbnailImage = [[UIImage alloc] initWithCGImage:thumbnailImageRef];
    
    [self cacheImage:thumbnailImage forKey:CACHE_KEY(imageID, self.thumbnailSize)];
    [self saveToFile:[self thumbnailPathForImageID:imageID] image:thumbnailImage];

    CGImageRelease(thumbnailImageRef);
    [thumbnailImage release];
}

- (void)loadThumbnailCacheWithImageIDs:(NSArray *)imageIDs
{
    for (NSString *imageID in imageIDs)
    {
        NSString *path = [self thumbnailPathForImageID:imageID];
        UIImage *thumbnailImage = [self imageFromCacheFile:path];
        if (thumbnailImage)
            [self cacheImage:thumbnailImage forKey:CACHE_KEY(imageID, self.thumbnailSize)];
        else
        {
            //
            // Something failed when generating a thumbnail, so lets re-generate.
            //
            CFURLRef pathURL = (CFURLRef)[NSURL fileURLWithPath:[self sourcePathForImageID:imageID]];
            CGImageSourceRef imageSource = CGImageSourceCreateWithURL(pathURL, NULL);
            
            [self generateThumbnailFromImageSource:nil forImageID:imageID];

            CFRelease(imageSource);
        }

    }
}

- (void)resizeImageSourceRef:(CGImageSourceRef)imageSource loader:(BKImageStoreLoader *)loader
{
    NSParameterAssert(imageSource);
    NSParameterAssert(loader);

    CFRetain(imageSource);
    dispatch_async(image_store_background_queue(), ^{
        //
        // Bail if we no longer have an image_block for this ID
        //
        if (loader.cancel)
        {
            CFRelease(imageSource);
            return;
        }
        
        //
        // Resize the image
        //   
        CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(imageSource,
                                                                  0, 
                                                                  [self resizeOptionsForMaxSize:loader.maxSize]);
        UIImage *image = [[UIImage alloc] initWithCGImage:imageRef];
        
      
        //
        // Cache the image and execute any pending blocks
        //
        [self cacheImage:image forKey:[loader cacheKey]];
        [self executeLoader:loader withImage:image];
        
        //
        // Save the image if flagged as a 'cached size', and then a thumbnail
        //
        if ([cachedFileSizes_ containsObject:[NSNumber numberWithUnsignedInteger:loader.maxSize]])
            [self saveToFile:[self cachedPathForKey:[loader cacheKey]] image:image];

        CGImageRelease(imageRef);
        [image release];

        CFRelease(imageSource);
    });
}

- (id)addLoaderForImageID:(NSString *)imageID sized:(NSUInteger)maxSize block:(bk_image_block)block
{
    NSParameterAssert(imageID);
    NSParameterAssert(block);
    NSString *key = CACHE_KEY(imageID, maxSize);
    UIImage *cachedImage = [self cacheImageForKey:key];
    if (cachedImage)
    {
        block(cachedImage);
        return nil;
    }
    else
    {
        BKImageStoreLoader *loader = [self loaderForBlock:block imageID:imageID sized:maxSize];

        if ([self preloadThumbnails])
            [self executeThumbnailForLoader:loader];

        //
        // Load the cached resize if it exists, otherwise kick off the resize
        //
        if ([self cachedFileExistsForKey:key])
        {
            [self loadFromCacheFile:loader];
        }
        else if ([self sourceFileExistsForImageID:imageID])
        {
            CFURLRef pathURL = (CFURLRef)[NSURL fileURLWithPath:[self sourcePathForImageID:imageID]];
            CGImageSourceRef imageSource = CGImageSourceCreateWithURL(pathURL, NULL);

            [self resizeImageSourceRef:imageSource loader:loader];
     
            CFRelease(imageSource);
        }
        return loader.loaderID;
    }
}

- (void)saveImageID:(NSString *)imageID 
           withData:(NSData*)imageData 
             onSave:(bk_save_block)saveBlock
            onError:(bk_error_block)errorBlock
{
    NSParameterAssert(imageID);
    NSParameterAssert(imageData);
 	dispatch_async(image_store_background_queue(), ^{        
        //
        // Save Image to disk, creating any needed directories before hand
        //
        NSString *path = [self sourcePathForImageID:imageID];
        NSError *error = nil;
        BOOL ok = [self saveImageData:imageData toPath:path error:&error];
        if (!ok)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                errorBlock(error);
                [self removeAllImageBlocksForImageID:imageID];
            });
            return;
        }
        // FIXME: How do I determine the size of imageData without loading too much data so I can resize !

        dispatch_async(dispatch_get_main_queue(), ^{
            saveBlock();
        });
            
        CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)imageData, NULL);

        if ([self preloadThumbnails])
        {
            [self generateThumbnailFromImageSource:imageSource forImageID:imageID];
        }

        //
        // Kick off resizes in the main thread for any pending BKImageStoreLoader objects
        //
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *loaders = nil;

            NSMutableDictionary *entries = [imageBlockEntries_ objectForKey:imageID];
            loaders = [entries allValues];

            // Kick off resizes for any block loaders in the system
            for (BKImageStoreLoader *loader in loaders)
            {
                [self resizeImageSourceRef:imageSource loader:loader];
            }
            CFRelease(imageSource);
        });
    });   
}

@end
