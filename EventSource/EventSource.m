//
//  EventSource.m
//  EventSource
//
//  Created by Neil on 25/07/2013.
//  Copyright (c) 2013 Neil Cowburn. All rights reserved.
//

#import "EventSource.h"
#import <CoreGraphics/CGBase.h>

NSString *const EventSourceErrorDomain = @"EventSourceErrorDomain";
NSString *const HTTPStatusCodeKey = @"EventSourceHTTPErrorCode";

static CGFloat const ES_RETRY_INTERVAL = 1.0;
static CGFloat const ES_DEFAULT_TIMEOUT = 600.0;
static CGFloat const ES_MAXIMUM_RETRY_INTERVAL = 360.0;
static CGFloat const ES_RETRY_INTERVAL_MULTYPLAYER = 2.0;

static NSString *const ESKeyValueDelimiter = @": ";
static NSString *const ESEventSeparatorLFLF = @"\n\n";
static NSString *const ESEventSeparatorCRCR = @"\r\r";
static NSString *const ESEventSeparatorCRLFCRLF = @"\r\n\r\n";
static NSString *const ESEventKeyValuePairSeparator = @"\n";

static NSString *const ESEventDataKey = @"data";
static NSString *const ESEventIDKey = @"id";
static NSString *const ESEventEventKey = @"event";
static NSString *const ESEventRetryKey = @"retry";

@interface EventSource () <NSURLConnectionDelegate, NSURLConnectionDataDelegate>

@property (nonatomic, strong) NSURL *eventURL;
@property (nonatomic, strong) NSURLConnection *eventSource;
@property (nonatomic, strong) NSMutableURLRequest *eventRequest;
@property (nonatomic, strong) NSMutableDictionary *listeners;
@property (nonatomic, assign) NSTimeInterval timeoutInterval;
@property (nonatomic, assign) NSTimeInterval retryInterval;
@property (nonatomic, strong) id lastEventID;
@property (nonatomic, strong) NSMutableData *dataBuffer;

@property (nonatomic, assign) BOOL wasClosed;

@property (nonatomic, assign) BOOL neverMoveToMain; // For testing proposes only

- (void)informListenersAboutEvent:(Event *)event ofType:(NSString *)type;
- (BOOL)isString:(NSString *)string containSuffix:(NSString *)suffix location:(NSInteger *)suffixLocation;
- (void)processCompleteEvents;

@end

@implementation EventSource

- (void)setShouldWorkInBackground:(BOOL)shouldWorkInBackground {
  __block BOOL isAppSupportVoIP = NO;
  [[NSBundle mainBundle].infoDictionary[@"UIBackgroundModes"] enumerateObjectsUsingBlock:^(NSString *mode, NSUInteger idx, BOOL *stop) {
    if ([mode isEqualToString:@"voip"]) {
      isAppSupportVoIP = YES;
      *stop = YES;
    }
  }];
  _shouldWorkInBackground = shouldWorkInBackground && isAppSupportVoIP;
}

+ (id)eventSourceWithURL:(NSURL *)URL
{
    return [[EventSource alloc] initWithURL:URL];
}

+ (id)eventSourceWithURL:(NSURL *)URL timeoutInterval:(NSTimeInterval)timeoutInterval
{
    return [[EventSource alloc] initWithURL:URL timeoutInterval:timeoutInterval];
}

+ (instancetype)eventSourceWithURL:(NSURL *)URL timeoutInterval:(NSTimeInterval)timeoutInterval eventId:(id)eventId {
    return [[EventSource alloc] initWithURL:URL timeoutInterval:timeoutInterval eventId:eventId];
}

- (id)initWithURL:(NSURL *)URL
{
    return [self initWithURL:URL timeoutInterval:ES_DEFAULT_TIMEOUT];
}

- (id)initWithURL:(NSURL *)URL timeoutInterval:(NSTimeInterval)timeoutInterval
{
    return [self initWithURL:URL timeoutInterval:timeoutInterval eventId:nil];
}

- (instancetype)initWithURL:(NSURL *)URL timeoutInterval:(NSTimeInterval)timeoutInterval eventId:(id)eventId {
    self = [super init];
    if (self) {
        _listeners = [NSMutableDictionary dictionary];
        _eventURL = URL;
        _timeoutInterval = timeoutInterval;
        _retryInterval = ES_RETRY_INTERVAL;
        _dataBuffer = [NSMutableData new];        
        _lastEventID = eventId;
        _shouldWorkInBackground = NO;
        _neverMoveToMain = YES;
    }
    return self;
}

- (void)dealloc {
  [self close];
}

- (void)addEventListener:(NSString *)eventName handler:(EventSourceEventHandler)handler
{
    if (_listeners[eventName] == nil) {
        [_listeners setObject:[NSMutableArray array] forKey:eventName];
    }
    
    [_listeners[eventName] addObject:handler];
}

- (NSArray *)listenersOfType:(id)type {
  return [self.listeners[type ?: MessageEvent] copy];
}

- (void)onMessage:(EventSourceEventHandler)handler
{
    [self addEventListener:MessageEvent handler:handler];
}

- (void)onError:(EventSourceEventHandler)handler
{
    [self addEventListener:ErrorEvent handler:handler];
}

- (void)onOpen:(EventSourceEventHandler)handler
{
    [self addEventListener:OpenEvent handler:handler];
}

- (void)open
{
    void (^open)() = ^void() {
        self.wasClosed = NO;
        if (!_eventRequest) {
            _eventRequest = [NSMutableURLRequest requestWithURL:self.eventURL
                                                    cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                timeoutInterval:self.timeoutInterval];
            if (self.shouldWorkInBackground) {
                [_eventRequest setNetworkServiceType:NSURLNetworkServiceTypeVoIP];
            }
        }
        if (self.lastEventID) {
            [_eventRequest setValue:self.lastEventID forHTTPHeaderField:@"Last-Event-ID"];
        }        
        if (_eventSource) {
            [_eventSource cancel];
            _eventSource = nil;
        }
        _eventSource = [[NSURLConnection alloc] initWithRequest:_eventRequest
                                                       delegate:self
                                               startImmediately:NO];
        [_eventSource scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        [_eventSource start];
  };
  
  if (![[NSThread mainThread] isMainThread]) {
      dispatch_async(dispatch_get_main_queue(), ^{
          open();
      });
  }
  else {
      open();
  }
}

- (void)close
{
    self.wasClosed = YES;
    [self.eventSource cancel];
    self.eventSource = nil;
}

- (void)informListenersAboutEvent:(Event *)event ofType:(NSString *)type {
  
    void (^informInCurrent)(EventSourceEventHandler, NSUInteger, BOOL*) = ^void(EventSourceEventHandler handler, NSUInteger idx, BOOL *stop) {
        handler(event);
    };
    void (^informInMain)(EventSourceEventHandler, NSUInteger, BOOL*) = ^void(EventSourceEventHandler handler, NSUInteger idx, BOOL *stop) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(event);
        });
    };
    void (^enumeration)(EventSourceEventHandler, NSUInteger, BOOL*) = ([[NSThread currentThread] isMainThread] || _neverMoveToMain) ? informInCurrent : informInMain;
  
    [[self listenersOfType:type] enumerateObjectsUsingBlock:enumeration];
    if (!type && event.event) {
        [[self listenersOfType:event.event] enumerateObjectsUsingBlock:enumeration];
    }
}

- (BOOL)isString:(NSString *)string containSuffix:(NSString *)suffix location:(NSInteger *)suffixLocation {
  NSInteger suffixIdx = [string rangeOfString:suffix options:NSBackwardsSearch].location;
  if (suffixIdx != NSNotFound && suffixLocation) {
      *suffixLocation = suffixIdx;
  }
  return (suffixIdx != NSNotFound);
}

- (void)processCompleteEvents
{
    NSString *eventString = [[NSString alloc] initWithData:self.dataBuffer encoding:NSUTF8StringEncoding];
    
    NSArray *eventSeparators = @[ESEventSeparatorLFLF, ESEventSeparatorCRCR, ESEventSeparatorCRLFCRLF];
    __block BOOL isContainEvents = NO;
    __block NSInteger lastEventSuffixIdx = NSNotFound;
    __block NSString *eventSeparator = nil;
    [eventSeparators enumerateObjectsUsingBlock:^(NSString *suffix, NSUInteger idx, BOOL *stop) {
        if ([self isString:eventString containSuffix:suffix location:&lastEventSuffixIdx]) {
            eventSeparator = suffix;
            *stop = isContainEvents = YES;
        }
    }];
    
    if (isContainEvents) {
        if (lastEventSuffixIdx < eventString.length - eventSeparator.length - 1) { // contain incomplete event
            NSString *incompleteEvent = [eventString substringFromIndex:lastEventSuffixIdx + eventSeparator.length];
            [self.dataBuffer setData:[incompleteEvent dataUsingEncoding:NSUTF8StringEncoding]];
        }
        else {
            [self.dataBuffer setData:[NSData new]];
        }
        eventString = [eventString substringToIndex:lastEventSuffixIdx];
        dispatch_queue_t procesingQueue = self.eventsHandlingQueue;
        if (!procesingQueue) {
          procesingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
        }
      
        dispatch_async(procesingQueue, ^{
            NSArray *eventsList = [eventString componentsSeparatedByString:eventSeparator];
            [eventsList enumerateObjectsUsingBlock:^(NSString *eventString, NSUInteger idx, BOOL *stop) {
                NSMutableArray *components = [[eventString componentsSeparatedByString:ESEventKeyValuePairSeparator] mutableCopy];
                
                Event *e = [Event new];
                e.readyState = kEventStateOpen;
                
                for (NSString *component in components) {
                    if (component.length == 0) {
                        continue;
                    }
                    
                    NSInteger index = [component rangeOfString:ESKeyValueDelimiter].location;
                    if (index == NSNotFound || index == (component.length - 2)) {
                        continue;
                    }
                    
                    NSString *key = [component substringToIndex:index];
                    NSString *value = [component substringFromIndex:index + ESKeyValueDelimiter.length];
                    
                    if ([key isEqualToString:ESEventIDKey]) {
                        e.id = value;
                        self.lastEventID = e.id;
                    } else if ([key isEqualToString:ESEventEventKey]) {
                        e.event = value;
                    } else if ([key isEqualToString:ESEventDataKey]) {
                        e.data = value;
                    } else if ([key isEqualToString:ESEventRetryKey]) {
                        self.retryInterval = [value doubleValue];
                    }
                }
                
                [self informListenersAboutEvent:e ofType:nil];
            }];
        });
    }
}

// ---------------------------------------------------------------------------------------------------------------------

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode == 200) {
        // Opened
        Event *e = [Event new];
        e.readyState = kEventStateOpen;
        [self informListenersAboutEvent:e ofType:OpenEvent];
      
        [self.dataBuffer setData:[NSData data]];
      
        self.retryInterval = ES_RETRY_INTERVAL;
    }
    else {
        Event *e = [Event new];
        e.error = [NSError errorWithDomain:EventSourceErrorDomain
                                      code:ESErrorWrongHTTPResponse
                                  userInfo:@{ NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Wrong HTTP response code: %ld", (long)httpResponse.statusCode],
                                              HTTPStatusCodeKey : @(httpResponse.statusCode) }];
        e.readyState = kEventStateClosed;
        [self informListenersAboutEvent:e ofType:ErrorEvent];
        [self close];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    Event *e = [Event new];
    e.readyState = kEventStateClosed;
    e.error = error;
  
    [self informListenersAboutEvent:e ofType:ErrorEvent];
  
    self.retryInterval = MIN(ES_MAXIMUM_RETRY_INTERVAL, self.retryInterval * ES_RETRY_INTERVAL_MULTYPLAYER);
    __weak EventSource *w_self = self;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.retryInterval * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
      if(!w_self.wasClosed) {
        [w_self open];
      }
    });
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    [self.dataBuffer appendData:data];
    [self processCompleteEvents];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    [self processCompleteEvents];
    [self.dataBuffer setData:[NSData new]];
  
    if (self.wasClosed) {
        return;
    }
    
    Event *e = [Event new];
    e.readyState = kEventStateClosed;
    e.error = [NSError errorWithDomain:EventSourceErrorDomain
                                  code:ESErrorConnectionClosedByServer
                              userInfo:@{ NSLocalizedDescriptionKey: @"Connection with the event source was closed." }];
    [self informListenersAboutEvent:e ofType:ErrorEvent];
  
    self.retryInterval = MIN(ES_MAXIMUM_RETRY_INTERVAL, self.retryInterval * ES_RETRY_INTERVAL_MULTYPLAYER);
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.retryInterval * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self open];
    });
}

@end

// ---------------------------------------------------------------------------------------------------------------------

@implementation Event

- (NSString *)description
{
    NSString *state = nil;
    switch (self.readyState) {
        case kEventStateConnecting:
            state = @"CONNECTING";
            break;
        case kEventStateOpen:
            state = @"OPEN";
            break;
        case kEventStateClosed:
            state = @"CLOSED";
            break;
    }
    
    return [NSString stringWithFormat:@"<%@: readyState: %@, id: %@; event: %@; data: %@>",
            [self class],
            state,
            self.id,
            self.event,
            self.data];
}

@end

NSString *const MessageEvent = @"message";
NSString *const ErrorEvent = @"error";
NSString *const OpenEvent = @"open";
