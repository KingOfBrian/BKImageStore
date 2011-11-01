/**
 *   Copyright 2011 King Software Design. All rights reserved.
 *
 * @class BKImageStore
 *
 * Purpose of BKImageStore is to simplify the saving and loading of camera images in a manner that is memory friendly
 *  and performant by default.   To that end, these are the goals:
 *
 * - Images are identified by an imageID - any unique string
 *   - Filenames based off of imageID's
 *   - imageID's with a / are grouped by directory
 *   - Data Model Independent
 *
 * - Minimize main thread processing 
 *   - Loading, Decompressing and Resizing done off thread
 *   - Block based API to load images when ready
 *   - Optionally execute blocks with thumbnails before fetching full sized images
 *
 * - Persist images in iOS5 friendly formats
 *   - Save source images in NSDocuments/<imageID>
 *   - Save thumbnails of a configurable size in NSDocuments/thumbnails/<imageID>
 *   - Optionally cache App sized images in NSCache/<imageID> to minimize resize 
 *      work at expense of disk space
 *
 * - Optimal Use of iOS frameworks
 *   - No UIImage imageWithFileName: - does not persist decompressed UIImage consistently
 *     - Thanks to @cocoanetics for putting his finger on that puzzle
 *        http://www.cocoanetics.com/2011/10/avoiding-image-decompression-sickness/
 *   - Write raw NSData from camera to disk.
 *   - Always resize images with CGImageSourceCreateThumbnailAtIndex
 *   - GCD everything, putting every time consuming operation into a separate block to maximize granularity
 *      - If the UI doesn't care about an object after loading but before re-sizing, it should not resize.
 *   - Use NSCache to handle low memory warnings
 *
 */

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#define APP_SIZE 480

typedef void (^bk_image_block)(UIImage* img);
typedef void (^bk_error_block)(NSError* error);
typedef void (^bk_save_block)();

@interface BKImageStore : NSObject {
    NSCache *cache_;
    NSMutableDictionary *imageBlockEntries_;
    NSMutableSet *cachedFileSizes_;
    
    NSUInteger thumbnailSize_;
    NSUInteger storageSize_;
    
    CGFloat jpegCompressionRatio_; 
    
    bk_error_block cacheFileIOErrorHandler_;
}

/**
 * Configuration routines
 * These properties setup the BKImageStore paramaters and should be configured 
 * directly after instatiation and never changed.
 */

/**
 * Size of the thumbnail to generate and to enable thumbnail preloading on cache misses
 */
@property (nonatomic, assign) NSUInteger thumbnailSize;
/**
 * FIXME: Not yet implemented
 * Max resolution to save on disk
 */
@property (nonatomic, assign) NSUInteger storageSize;

/** 
 * JPEG compression ratio when saving jpeg's to disk
 * Defaults to 0.65, my favorite size/quality trade off
 */
@property (nonatomic, assign) CGFloat jpegCompressionRatio;

/**
 * Error block to execute if there are any errors writing 
 *  files to disk while generating thumbnails or cache sizes
 */
@property (nonatomic, copy) bk_error_block cacheFileIOErrorHandler;

/**
 * Specify a size to cache to disk.  If your app is using one size most of the time
 *  this will improve loading performance at the expense of save time and disk space.
 *
 *  FIXME: Not sure why I chose to have multiple size's here, Should be changed
 *  FIXME: Use CGSize and look at the image orientation to determine proper max size
 */
- (void)addCachedFileSize:(NSUInteger)size;

/**
 * A shared BKImageStore.   Not a singleton as multiple BKImageStore can exist.
 * FIXME: rename to defaultStore
 */
+ (BKImageStore *)sharedStore;

/**
 * Load thumbnail images from disk into cache.
 *
 *  Iterate through all of the imageIDs and load the files into cache.  
 *    If a thumbnail file does not exist, a file will be created from the source file.
 *
 *  This call is not asyncronous and CAN be called on or off the main thread.
 *  This call can only be executed after 
 */
- (void)loadThumbnailCacheWithImageIDs:(NSArray *)imageIDs;

/**
 * Load imageID with the max resolution of maxSize and execute the 
 *  specified image_block as soon as it is ready.  If the image is not in the cache,
 *  it will return a token that you can hold onto, and if you don't care about the 
 *  image_block being executed, run removeImageBlockID:forImageID:.  This will prevent
 *  the UI from thrashing the image store too much.
 *  
 *
 * In short, this is the algorithm used:
 *
 * Look for an image in the cache of _maxSize_ and if it exists, execute image_block
 * Otherwise:
 *   If thumbnailSize is set, and a thumbnail image is in the cache, 
 *       execute image_block(thumbnail) to get some bits on screen
 *   If the size is in _cachedFileSizes_, and the NSCache/<imageID> file exists
 *       load the file off main thread, decompress and execute image_block
 *   If the source file exists on disk, kick off a resize off main thread
 *       if the size is in _cachedFileSizes_ save it to disk afterwards
 *         Ideally this never occurs, but can under duress.
 *   If no image exists, save some state so the image_block is executed
 *       later when the image is populated with saveImageID:withData:onSave:onError
 *
 *  This call can ONLY be called on main thread
 */
- (id)loadImageID:(NSString *)imageID 
            sized:(NSUInteger)maxSize
            block:(bk_image_block)block;

/**
 * Save the image represented by _imageData_ to disk as imageID and execute saveBlock || errorBlock
 *
 * - Write _imageData_ to disk, 
 * - Perform any resizes for previous loadImageID:sized:block: calls
 * - Generate a thumbnail image if thumbnailSize has been set
 *
 *  This call can ONLY be called on main thread
 */
- (void)saveImageID:(NSString *)imageID 
           withData:(NSData*)imageData 
             onSave:(bk_save_block)saveBlock
            onError:(bk_error_block)errorBlock;

/**
 * Cancel the operation associated with the loaderID associated with imageID
 *
 *  This call can ONLY be called on main thread
 * FIXME: imageID should not be required
 */
- (void)removeImageBlockID:(id)loaderID forImageID:(NSString *)imageID;

/**
 * Cancel the operation associated with the loaderID.
 * 
 *  This call can ONLY be called on main thread
 */
- (void)removeAllImageBlocksForImageID:(NSString *)imageID;

// FIXME: Implement
//- (void)deleteImageID:(NSString *)imageID;
@end
