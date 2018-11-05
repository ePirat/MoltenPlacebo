//
//  main.m
//  MoltenPlacebo
//
//  This proof-of-concept is extremely naive. This is probably not
//  what you should be doing for a real program!
//
//  Created by Marvin Scholz on 05.11.18.
//  Based on sdl.c
//
//  License: CC0 / Public Domain
//
#include <sys/time.h>

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>

#import <MoltenVK/mvk_vulkan.h>

#import <libplacebo/renderer.h>
#import <libplacebo/utils/upload.h>
#import <libplacebo/vulkan.h>

// Uncomment to add the metal view as subview
// instead of setting the metal view as contentView
// of the Main Window
// #define ADD_METAL_VIEW_AS_SUBVIEW

// Uncomment to use a MTKView instead of the custom
// NSView subclass with a metal layer
// #define USE_MTKVIEW

// Uncomment to use DisplayLink
// #define USE_DISPLAYLINK

#pragma mark -
#pragma mark Application delegate interface

@interface AppDelegate : NSObject <NSApplicationDelegate> {
    VkSurfaceKHR vk_surface;
    struct pl_context *pl_ctx;

    const struct pl_vulkan *pl_vk;
    const struct pl_vk_inst *pl_vk_instance;
    const struct pl_swapchain *pl_swapch;

    // For rendering
    const struct pl_tex *pl_img_tex;
    const struct pl_tex *pl_osd_tex;
    struct pl_plane pl_img_plane;
    struct pl_plane pl_osd_plane;
    struct pl_renderer *pl_renderer;

    CVDisplayLinkRef _displayLink;
    double _lastTime;
    double _deltaToLastFrame;

    unsigned int frames;

    NSThread *_renderThread;
}

@property (weak) IBOutlet NSWindow *window;

- (void)displayLink:(CVDisplayLinkRef)displayLink tickWithTime:(const CVTimeStamp*)inNow;
@end

#pragma mark -
#pragma mark MetalBackedLayerView interface
@interface MetalBackedLayerView : NSView

@end

#pragma mark -
#pragma mark Display link callback
static CVReturn DisplayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *displayLinkContext)
{
    CVTimeStamp inNowCopy = *inNow;
    dispatch_async(dispatch_get_main_queue(), ^{
        AppDelegate *delegate = (__bridge AppDelegate*)displayLinkContext;
        [delegate displayLink:displayLink tickWithTime:&inNowCopy];
    });
    return kCVReturnSuccess;
}

#pragma mark -
#pragma mark Application delegate implementation

@implementation AppDelegate

#pragma mark -
#pragma mark Placebo and Vulkan init

- (void)initPlacebo {
    pl_ctx = pl_context_create(PL_API_VER, &(struct pl_context_params) {
        .log_cb    = (0) ? pl_log_color : pl_log_simple,
        .log_level = PL_LOG_DEBUG,
    });

    assert(pl_ctx);
}

- (void)initVulkan {
    struct pl_vk_inst_params iparams = pl_vk_inst_default_params;

    iparams.extensions = (const char *[]) { VK_MVK_MACOS_SURFACE_EXTENSION_NAME };
    iparams.num_extensions = 1;

    pl_vk_instance = pl_vk_inst_create(pl_ctx, &iparams);
    if (!pl_vk_instance) {
        fprintf(stderr, "Failed creating vulkan instance!");
        exit(2);
    }

    // Add Metal View

#ifdef USE_MTKVIEW
    MTKView *metalView = [[MTKView alloc] initWithFrame:_window.contentView.frame
                                                 device:nil];
    NSAssert(metalView != nil, @"Metal MTKView initialization failure");
#else
    MetalBackedLayerView *metalView = [[MetalBackedLayerView alloc]
                                       initWithFrame:_window.contentView.frame];
    [metalView setWantsLayer:YES];
    [metalView setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawNever];
    NSAssert(metalView != nil, @"Metal View initialization failure");
#endif

#ifdef ADD_METAL_VIEW_AS_SUBVIEW
    [metalView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_window.contentView addSubview:metalView];
#else
    [_window setContentView:metalView];
#endif

    // Create Vulkan surface
    VkMacOSSurfaceCreateInfoMVK surface_info;
    surface_info.sType = VK_STRUCTURE_TYPE_MACOS_SURFACE_CREATE_INFO_MVK;
    surface_info.pNext = NULL;
    surface_info.flags = 0;
    surface_info.pView = (__bridge void*)metalView;

    VkResult err = vkCreateMacOSSurfaceMVK(pl_vk_instance->instance,
                                           &surface_info,
                                           NULL,
                                           &vk_surface);

    NSAssert(!err, @"Vulkan macOS surface creation");

    struct pl_vulkan_params params = pl_vulkan_default_params;
    params.instance = pl_vk_instance->instance;
    params.surface = vk_surface;
    params.allow_software = true;
    params.async_compute = false;
    params.async_transfer = false;
    pl_vk = pl_vulkan_create(pl_ctx, &params);
    if (!pl_vk) {
        fprintf(stderr, "Failed creating vulkan device!");
        exit(2);
    }

    pl_swapch = pl_vulkan_create_swapchain(pl_vk, &(struct pl_vulkan_swapchain_params) {
        .surface = vk_surface,
        .present_mode = VK_PRESENT_MODE_IMMEDIATE_KHR,
        //.present_mode = VK_PRESENT_MODE_FIFO_KHR,
    });

    if (!pl_swapch) {
        fprintf(stderr, "Failed creating vulkan swapchain!");
        exit(2);
    }
}

- (void)initDisplayLink
{
    CVReturn ret = CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    NSAssert(ret == kCVReturnSuccess, @"Failed creating display link!");

    CVDisplayLinkSetOutputCallback(_displayLink, DisplayLinkCallback, (__bridge void*) self);
}

- (void)startDisplayLink
{
    CVReturn ret = CVDisplayLinkStart(_displayLink);
    NSAssert(ret == kCVReturnSuccess, @"Failed starting display link!");
}

- (void)stopDisplayLink
{
    CVReturn ret = CVDisplayLinkStop(_displayLink);
    NSAssert(ret == kCVReturnSuccess, @"Failed stopping display link!");
}

- (void)displayLink:(CVDisplayLinkRef)displayLink tickWithTime:(const CVTimeStamp*)inNow
{
    struct pl_swapchain_frame frame;
    bool ok = pl_swapchain_start_frame(pl_swapch, &frame);
    if (!ok) {
        NSLog(@"pl_swapchain_start_frame failed!");
    }

    [self renderFrame:&frame];
    ok = pl_swapchain_submit_frame(pl_swapch);
    if (!ok) {
        fprintf(stderr, "Failed submitting frame!");
        exit(3);
    }

    pl_swapchain_swap_buffers(pl_swapch);
}

- (void)initAndStartRenderThread
{
    _renderThread = [[NSThread alloc] initWithTarget:self
                                            selector:@selector(renderThreadMain:)
                                              object:nil];
    [_renderThread start];
}

static unsigned long getTicks() {
    struct timeval tval;
    gettimeofday(&tval, NULL);
    return tval.tv_sec * 1000 + tval.tv_usec / 1000;
}

- (void)renderThreadMain:(id)obj
{
    unsigned long last = getTicks();
    unsigned int frames = 0;

    while (!_renderThread.isCancelled) {
        struct pl_swapchain_frame frame;
        bool ok = pl_swapchain_start_frame(pl_swapch, &frame);
        if (!ok) {
            NSLog(@"pl_swapchain_start_frame failed!");
            continue;
        }

        [self renderFrame:&frame];
        ok = pl_swapchain_submit_frame(pl_swapch);
        if (!ok) {
            fprintf(stderr, "Failed submitting frame!");
            exit(3);
        }

        pl_swapchain_swap_buffers(pl_swapch);
        frames++;

        unsigned long now = getTicks();
        if (now - last > 5000) {
            printf("%u frames in %lu ms = %f FPS\n", frames, now - last,
                   1000.0f * frames / (now - last));
            last = now;
            frames = 0;
        }
    }
}

- (void)stopRenderThread
{
    [_renderThread cancel];
}

#pragma mark -
#pragma mark Rendering related things

- (BOOL)uploadPlaneFromImageURL:(NSURL *)url
                      toTexture:(const struct pl_tex **)tex
                       andPlane:(struct pl_plane *)plane
{
    CIImage *image = [CIImage imageWithContentsOfURL:url];
    if (image == nil) {
        NSLog(@"CIImage creation failed!");
        return NO;
    }

    CGRect imageRect = [image extent];
    NSUInteger bytesPerPixel = 4;
    NSUInteger bytesPerRow = bytesPerPixel * imageRect.size.width;
    NSUInteger totalBytes = bytesPerRow * imageRect.size.height;
    void *bitmap = calloc(totalBytes, sizeof(UInt8));

    CIContext *ciContext = [CIContext context];
    [ciContext render:image
             toBitmap:bitmap
             rowBytes:bytesPerRow
               bounds:imageRect
               format:kCIFormatABGR8
           colorSpace:nil];

    struct pl_plane_data data = {
        .type           = PL_FMT_UNORM,
        .pixel_stride   = bytesPerPixel,
        .row_stride     = 0,
        .width          = imageRect.size.width,
        .height         = imageRect.size.height,
        .pixels         = bitmap
    };

    uint64_t masks[4] = { 0xFF000000, 0xFF0000, 0xFF00, 0xFF };
    pl_plane_data_from_mask(&data, masks);

    bool ok = pl_upload_plane(pl_vk->gpu, plane, tex, &data);

    free(bitmap);

    if (!ok) {
        NSLog(@"pl_upload_plane failed!");
        return NO;
    }
    return YES;
}

- (void)initRenderingWithImageURL:(NSURL *)imgURL andOSDURL:(NSURL *)osdURL
{
    if (![self uploadPlaneFromImageURL:imgURL
                             toTexture:&pl_img_tex
                              andPlane:&pl_img_plane]) {
        fprintf(stderr, "Failed uploading image plane!\n");
        exit(2);
    }

    // Create a renderer instance
    pl_renderer = pl_renderer_create(pl_ctx, pl_vk->gpu);
}

- (void)deinitAllStuff
{
    pl_renderer_destroy(&pl_renderer);
    pl_tex_destroy(pl_vk->gpu, &pl_img_tex);
    pl_tex_destroy(pl_vk->gpu, &pl_osd_tex);
    pl_swapchain_destroy(&pl_swapch);
    pl_vulkan_destroy(&pl_vk);
    vkDestroySurfaceKHR(pl_vk_instance->instance, vk_surface, NULL);
    pl_vk_inst_destroy(&pl_vk_instance);
    pl_context_destroy(&pl_ctx);
}

- (void)renderFrame:(const struct pl_swapchain_frame *)frame
{
    const struct pl_tex *img = pl_img_plane.texture;
    struct pl_image image = {
        .num_planes = 1,
        .planes     = { pl_img_plane },
        .repr       = pl_color_repr_unknown,
        .color      = pl_color_space_unknown,
        .width      = img->params.w,
        .height     = img->params.h,
    };

    // This seems to be the case for SDL2_image
    image.repr.alpha = PL_ALPHA_INDEPENDENT;

    // Use a slightly heavier upscaler
    struct pl_render_params render_params = pl_render_default_params;
    //render_params.upscaler = &pl_filter_ewa_lanczos;

    struct pl_render_target target;
    pl_render_target_from_swapchain(&target, frame);

    /*
    target.profile = (struct pl_icc_profile) {
        .data = icc_profile.data,
        .len = icc_profile.size,
    };
    */

    //const struct pl_tex *osd = pl_osd_plane.texture;
    const struct pl_tex *osd = NULL;
    if (osd) {
        target.num_overlays = 1;
        target.overlays = &(struct pl_overlay) {
            .plane      = pl_osd_plane,
            .rect       = { 0, 0, osd->params.w, osd->params.h },
            .mode       = PL_OVERLAY_NORMAL,
            .repr       = image.repr,
            .color      = image.color,
        };
    }

    if (!pl_render_image(pl_renderer, &image, &target, &render_params)) {
        fprintf(stderr, "Failed rendering frame!\n");
        [self deinitAllStuff];
        exit(2);
    }
}

#pragma mark -
#pragma mark App lifetime management

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSLog(@"Hi!");
    [self initPlacebo];
    [self initVulkan];

    NSURL *imageURL = [NSURL URLWithString:@"file:///Users/epirat/Downloads/koYTMsUI_400x400.png"];
    [self initRenderingWithImageURL:imageURL andOSDURL:nil];

#ifdef USE_DISPLAYLINK
    [self initDisplayLink];
    [self startDisplayLink];
#else
    [self initAndStartRenderThread];
#endif
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
#ifdef USE_DISPLAYLINK
    [self stopDisplayLink];
#else
    [self stopRenderThread];
#endif

    [self deinitAllStuff];
    NSLog(@"Bye!");
}

@end

#pragma mark -
#pragma mark Main method

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Create a basic application
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Main Menu bar
        NSMenu *mainMenu = [NSMenu new];

        // Application menu item
        NSMenuItem *appMenuItem = [NSMenuItem new];
        [mainMenu addItem:appMenuItem];

        // Set main menu
        [NSApp setMainMenu:mainMenu];

        // Applicaion menu
        NSMenu *appMenu = [NSMenu new];

        // Quit item
        NSString* appName = [[NSProcessInfo processInfo] processName];
        NSString* quitText = [NSString stringWithFormat:@"Quit %@", appName];
        NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:quitText
                                                          action:@selector(terminate:)
                                                   keyEquivalent:@"q"];
        [appMenu addItem:quitItem];
        [appMenuItem setSubmenu:appMenu];

        // Main window position calculation (center)
        NSRect screenFrame = [[NSScreen mainScreen] frame];
        NSSize windowSize = NSMakeSize(600, 480);
        NSRect initialFrame = NSMakeRect(NSWidth(screenFrame) / 2 - windowSize.width / 2,
                                         NSHeight(screenFrame) / 2 - windowSize.height / 2,
                                         windowSize.width,
                                         windowSize.height);

        // Create main window
        NSWindow *window = [[NSWindow alloc] initWithContentRect:initialFrame
                                                       styleMask:NSWindowStyleMaskTitled
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
        [window setTitle:appName];
        [window makeKeyAndOrderFront:nil];

        window.styleMask |= NSWindowStyleMaskMiniaturizable
            | NSWindowStyleMaskClosable
            | NSWindowStyleMaskResizable;

        // App delegate
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [delegate setWindow:window];
        [NSApp setDelegate:delegate];

        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
        return 0;
    }
}

#pragma mark -
#pragma mark MetalBackedLayerView implementation

@implementation MetalBackedLayerView

- (BOOL)wantsUpdateLayer {
    return YES;
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (CALayer*)makeBackingLayer {
    CALayer* layer = [self.class.layerClass layer];
    return layer;
}

@end
