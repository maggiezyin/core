//
//  SyrBridge.m
//  SyrNative
//
//  Created by Anderson,Derek on 10/5/17.
//  Copyright © 2017 Anderson,Derek. All rights reserved.
//

#import "SyrBridge.h"
#import "SyrEventHandler.h"
#import "SyrRaster.h"
#import "SyrEventHandler.h"
#import "sys/utsname.h"

@interface SyrBridge()
@property SyrEventHandler* eventHandler;
@property SyrRaster* raster;
@property WKWebView* bridgedBrowser;
@property SyrRootView* rootView;
@property NSMutableDictionary* instances;
@property NSMutableDictionary* rootViews;
@end

@implementation SyrBridge

- (id) init
{
  self = [super init];

  if (self!=nil) {
    // js bridge configuration
    WKUserContentController *controller = [[WKUserContentController alloc] init];
    [controller addScriptMessageHandler:self name:@"SyrNative"];
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.userContentController = controller;

    // setup a 0,0,0,0 wkwebview to use the js bridge
    _bridgedBrowser = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 0, 0) configuration:configuration];
    _bridgedBrowser.navigationDelegate = self;
    _rootViews = [[NSMutableDictionary alloc] init];
    // connect the bridge to other components
    _eventHandler = [SyrEventHandler sharedInstance];
    _eventHandler.bridge = self;
    _raster = [SyrRaster sharedInstance];
    _raster.bridge = self;
  }

  return self;
}

/**
 load the javascript bundle.
 we use an html fixture to aid in loading

 we pass as query the native modules available
 and envrionment info
 */
- (void) loadBundle: (NSString*) withBundlePath withRootView: (SyrRootView*) rootView
{
  // load a bundle with the root view we were handed
  // @TODO multiplex bridge : multiple apps, one instance
  NSString *uuid = [[NSUUID UUID] UUIDString];
  _rootView = rootView;
  
  // store the rootView being loaded
  [_rootViews setObject:rootView forKey:uuid];

  NSURL* syrBridgeUrl;
  if([withBundlePath containsString:@"http"]) {
    syrBridgeUrl = [NSURL URLWithString:withBundlePath];
  } else {
    [_bridgedBrowser.configuration.preferences setValue:@TRUE forKey:@"allowFileAccessFromFileURLs"];
    syrBridgeUrl = [NSURL fileURLWithPath:withBundlePath];
  }

  NSURLComponents *components = [NSURLComponents componentsWithURL:syrBridgeUrl resolvingAgainstBaseURL:YES];
  NSMutableArray* exportedMethods = [[NSMutableArray alloc] init];

  // pass native module names and selectors to the javascript side
  NSMutableArray *queryItems = [NSMutableArray array];
  for (NSString *key in _raster.nativemodules) {
    NSString *new = [key stringByReplacingOccurrencesOfString: @"__syr_export__" withString:@"_"];
    [exportedMethods addObject:new];
  }

  // setup some environment stuff for the interpreter
  NSNumber* width = [NSNumber numberWithDouble:[UIScreen mainScreen].bounds.size.width];
  NSNumber* height = [NSNumber numberWithDouble:[UIScreen mainScreen].bounds.size.height];
  NSDictionary* bootupProps = [rootView appProperties];

  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:bootupProps
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:nil];

  NSData *jsonExportedMethodsData = [NSJSONSerialization dataWithJSONObject:exportedMethods
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:nil];

  NSString* uriStringExportedMethods = [[NSString alloc] initWithData:jsonExportedMethodsData encoding:NSUTF8StringEncoding];
  NSString* uriStringBootupProps = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

  CGFloat screenScale = [[UIScreen mainScreen] scale];
  NSNumber* screenScaleNS = [NSNumber numberWithFloat:screenScale];

  [queryItems addObject:[NSURLQueryItem queryItemWithName:@"initial_props" value:uriStringBootupProps]];
  [queryItems addObject:[NSURLQueryItem queryItemWithName:@"window_width" value:[width stringValue]]];
  [queryItems addObject:[NSURLQueryItem queryItemWithName:@"window_height" value:[height stringValue]]];
  [queryItems addObject:[NSURLQueryItem queryItemWithName:@"screen_density" value:[screenScaleNS stringValue]]];
  [queryItems addObject:[NSURLQueryItem queryItemWithName:@"platform" value:@"ios"]];
  [queryItems addObject:[NSURLQueryItem queryItemWithName:@"platform_version" value:[[UIDevice currentDevice] systemVersion]]];
  [queryItems addObject:[NSURLQueryItem queryItemWithName:@"exported_methods" value:uriStringExportedMethods]];
  [queryItems addObject:[NSURLQueryItem queryItemWithName:@"model" value:[self deviceName]]];
  [queryItems addObject:[NSURLQueryItem queryItemWithName:@"rootViewId" value:uuid]];

  components.queryItems = queryItems;
  NSURLRequest * req = [NSURLRequest requestWithURL:components.URL];
  // [_bridgedBrowser loadFileURL:components.URL allowingReadAccessToURL:components.URL];
  [_bridgedBrowser loadRequest:req];

  [NSTimer scheduledTimerWithTimeInterval:2.0
                                   target:self
                                 selector:@selector(heartBeat)
                                 userInfo:nil
                                  repeats:YES];
}

-(NSString*) resourceBundlePath
{
  return [_rootView resourceBundlePath];
}

- (void) heartBeat {
  NSString* js = [NSString stringWithFormat:@""];

  // dispatching on the bridge to wkwebview needs to be done on the main thread
  dispatch_async(dispatch_get_main_queue(), ^{
    [self->_bridgedBrowser evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
      if (error == nil)
      {
        // @TODO do something with JS returns here
      }
      else
      {
        NSLog(@"evaluateJavaScript error : %@", error.localizedDescription);
      }
    }];
  });
}

/**
 the bridge sending a message for us to act on
 */
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {

  NSDictionary* syrMessage = [message valueForKey:@"body"];
  NSString* messageType = [syrMessage valueForKey:@"type"];
  NSString* messageSender = [syrMessage valueForKey:@"sender"];
  SyrRootView* recievingRootView = [_rootViews objectForKey:messageSender];
  
  if([messageType containsString:@"cmd"]) {

    // keep messaging on the async queue
    [self invokeMethodWithMessage:syrMessage];
  } else if([messageType containsString:@"gui"]) {

    // updating the UI needs to be done on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_raster parseAST:syrMessage withRootView:recievingRootView];
    });

  } else if([messageType containsString:@"animation"]) {

    // animations define the thread they are on
    [_raster setupAnimation:syrMessage];
  } else if([messageType containsString:@"error"]) {
    [_raster showInfoMessage:syrMessage withRootView:recievingRootView];
  }
}

/**
 Invoke a class method from the signature we are given.
 assume the data types, and use NSObject to pass them through
 */
- (void)invokeMethodWithMessage: (NSDictionary*) syrMessage
{
  NSData *objectData = [[syrMessage valueForKey:@"ast"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *astDict = [NSJSONSerialization JSONObjectWithData:objectData
                                                          options:NSJSONReadingMutableContainers
                                                            error:nil];

  // get the class
  NSString* className = [_raster.registeredClasses valueForKey:[astDict valueForKey:@"clazz"]];
  Class class = NSClassFromString(className);

  // create an instance of the object
  if(class != nil){
    [_instances setObject:class forKey:className];
  }

  // get render method
  NSString* selectorString = [NSString stringWithFormat:@"__syr_export__%@", [astDict valueForKey:@"method"]];
  SEL methodSelector = NSSelectorFromString(selectorString);
  if ([class respondsToSelector:methodSelector]) {

    NSMethodSignature *methodSignature = [NSClassFromString(className) methodSignatureForSelector:methodSelector];
    //invoke render method, pass component
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:methodSignature];

    [inv setSelector:methodSelector];
    [inv setTarget:class];

    NSData *argsData = [[astDict valueForKey:@"args"] dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error;
    // Note that JSONObjectWithData will return either an NSDictionary or an NSArray,
    // depending whether your JSON string represents an a dictionary or an array.
    id argsObject = [NSJSONSerialization JSONObjectWithData:argsData options:0 error:&error];
    int argsIndex = 2; // start at 2
    for(id arg in argsObject) {
      NSObject* argObj = [argsObject objectForKey:arg];
      [inv setArgument:&(argObj) atIndex:argsIndex];
      argsIndex = argsIndex + 1;
    }
    [inv invoke];
  }
}

/**
 if the page is refreshed, we need to thrash the render
 @TODO - ensure this isn't leaking
 @TODO - needs to clear per application
 */
- (void)webView:(WKWebView *)webView
        didStartProvisionalNavigation:(WKNavigation *)navigation
{
  NSLog(@"Reloading Bundle");
  // bundle reloaded, remove all subviews from root view
  [_raster reset];
  [_rootView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
}

/**
 send an event to through the bridge to the javascript side.
 @TODO - handle errors
 */
- (void) sendEvent: (NSDictionary*) message {
  // send events on an async queue
  dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0ul);
  dispatch_async(queue, ^{
    NSData *messageData = [NSJSONSerialization dataWithJSONObject:message
                                                          options:NSJSONWritingPrettyPrinted
                                                            error:nil];
    NSString *messageString = [[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding];
    NSString* js = [NSString stringWithFormat:@"SyrEvents.emit(%@)", messageString];

    // dispatching on the bridge to wkwebview needs to be done on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_bridgedBrowser evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        if (error == nil)
        {
          // do something with JS returns here
        }
        else
        {
          NSLog(@"evaluateJavaScript error : %@", error.localizedDescription);
        }
      }];
    });
  });
}

- (void)webView:(WKWebView *)webView
        didFailProvisionalNavigation:(WKNavigation *)navigation
        withError:(NSError *)error
{
  NSLog(@"error");
}

/**
 delegate method for the raster to invoke when it has added the UI component to a parent
 */
- (void) rasterRenderedComponent: (NSString*) withComponentId {
  NSDictionary* event = @{@"guid":withComponentId, @"type":@"componentDidMount"};
  [self sendEvent:event];
}

- (void) rasterRemovedComponent: (NSString*) withComponentId {
  NSDictionary* event = @{@"guid":withComponentId, @"type":@"componentWillUnmount"};
  [self sendEvent:event];
}

- (NSString*) deviceName
{
    struct utsname systemInfo;
    uname(&systemInfo);

    return [NSString stringWithCString:systemInfo.machine
                              encoding:NSUTF8StringEncoding];
}

@end
