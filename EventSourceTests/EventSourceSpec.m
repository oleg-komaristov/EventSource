//
//  EventSourceSpec.m
//  EventSource
//
//  Created by Oleg Komaristov on 4/12/15.
//  Copyright 2015 Oleg Komaristov. All rights reserved.
//

#import <Kiwi/Kiwi.h>
#import "EventSource.h"

@interface EventSource (TESTING) <NSURLConnectionDelegate, NSURLConnectionDataDelegate>

@property (nonatomic, strong) NSURL *eventURL;
@property (nonatomic, strong) NSURLConnection *eventSource;
@property (nonatomic, strong) NSMutableDictionary *listeners;
@property (nonatomic, assign) NSTimeInterval timeoutInterval;
@property (nonatomic, assign) NSTimeInterval retryInterval;
@property (nonatomic, strong) id lastEventID;
@property (nonatomic, strong) NSMutableData *dataBuffer;

@property (nonatomic, assign) BOOL neverMoveToMain;

- (void)informListenersAboutEvent:(Event *)event ofType:(NSString *)type;
- (BOOL)isString:(NSString *)string containSuffix:(NSString *)suffix location:(NSInteger *)suffixLocation;
- (void)processCompleteEvents;

@end

SPEC_BEGIN(EventSourceSpec)

describe(@"EventSource", ^{
  __block NSURL *testURL;
  __block EventSource *source;
  __block id connectionMock;
  
  beforeAll(^{
    testURL = [NSURL URLWithString:@"http://test-events-server.com"];
  });
  
  beforeEach(^{
    source = [EventSource eventSourceWithURL:testURL];
    connectionMock = [KWMock mockForClass:[NSURLConnection class]];
    source.eventSource = connectionMock;
  });
  
  it(@"should init with URL", ^{
    
    EventSource *source = [EventSource eventSourceWithURL:testURL];
    [[source.eventURL should] equal:testURL];
    source = [[EventSource alloc] initWithURL:testURL];
    [[source.eventURL should] equal:testURL];
  });
  
  it(@"should init with right timeout interval", ^{
    source = [EventSource eventSourceWithURL:testURL timeoutInterval:10.f];
    [[source.eventURL should] equal:testURL];
    [[theValue(source.timeoutInterval) should] equal:10.f withDelta:0.001f];
    source = [[EventSource alloc] initWithURL:testURL timeoutInterval:10.f];
    [[theValue(source.timeoutInterval) should] equal:10.f withDelta:0.001f];
  });
  
  it(@"should open connection", ^{
    source.eventSource = nil;
    [source open];
    [[source.eventSource should] beNonNil];
  });
  
  context(@"listeners informing", ^{
    __block BOOL wasCalled = NO;
    
    beforeEach(^{
      connectionMock = [KWMock mockForClass:[NSURLConnection class]];
      source.eventSource = connectionMock;
      source.neverMoveToMain = YES;
      wasCalled = NO;
    });
    
    afterEach(^{
      [[theValue(wasCalled) should] beYes];
    });
    
    it(@"should inform about connection opened", ^{
      [source onOpen:^(Event *event) {
        [[theValue(event.readyState) should] equal:theValue(kEventStateOpen)];
        wasCalled = YES;
      }];
      NSURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:testURL
                                                            statusCode:200
                                                           HTTPVersion:@"2"
                                                          headerFields:nil];
      [source connection:connectionMock didReceiveResponse:response];
    });
    
    it(@"should inform about connection error", ^{
      NSError *error = [NSError new];
      [source onError:^(Event *event) {
        [[theValue(event.readyState) should] equal:theValue(kEventStateClosed)];
        [[event.error should] equal:error];
        wasCalled = YES;
      }];
      [source connection:connectionMock didFailWithError:error];
      
    });
    
    it(@"should inform about wrong HTTP code in response", ^{
      NSInteger wrongCode = 500;
      [connectionMock stub:@selector(cancel)];
      [source onError:^(Event *event) {
        [[event.error.domain should] equal:EventSourceErrorDomain];
        [[theValue(event.error.code) should] equal:theValue(ESErrorWrongHTTPResponse)];
        [[theValue(event.readyState) should] equal:theValue(kEventStateClosed)];
        wasCalled = YES;
      }];
      NSURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:testURL
                                                            statusCode:wrongCode
                                                           HTTPVersion:@"2"
                                                          headerFields:nil];
      [source connection:connectionMock didReceiveResponse:response];
    });
    
    it(@"should inform about connection close", ^{
      [source onError:^(Event *event) {
        [[event.error.domain should] equal:EventSourceErrorDomain];
        [[theValue(event.error.code) should] equal:theValue(ESErrorConnectionClosedByServer)];
        [[theValue(event.readyState) should] equal:theValue(kEventStateClosed)];
        wasCalled = YES;
      }];
      [source connectionDidFinishLoading:connectionMock];
    });
    
    context(@"events processing", ^{
      __block NSNumber *eventId;
      __block NSString *eventData;
      __block dispatch_semaphore_t semaphore;
      __block NSData *(^data)(NSString *);
      __block void (^validateEvent)(Event *);
      
      beforeAll(^{
        eventId = @1024;
        eventData = @"event data";
        data = ^NSData *(NSString *event) {
          NSString *dataString = [NSString stringWithFormat:@"id: %@\ndata: %@\n\n", eventId, eventData];
          if (event) {
            dataString = [[NSString stringWithFormat:@"event: %@\n", event] stringByAppendingString:dataString];
          }
          return [dataString dataUsingEncoding:NSUTF8StringEncoding];
        };
        validateEvent = ^void(Event *event) {
          [[theValue([event.id integerValue]) should] equal:eventId];
          [[event.data should] equal:eventData];
          wasCalled = YES;
          dispatch_semaphore_signal(semaphore);
        };
      });
      
      beforeEach(^{
        semaphore = dispatch_semaphore_create(0);
        [source onMessage:validateEvent];
      });
      
      it(@"shuold inform about message received", ^{
        [source connection:connectionMock didReceiveData:data(nil)];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
      });
      
      it(@"shuold inform about message received in 2 reposnes", ^{
        NSData *income = data(nil);
        NSInteger breakPosition = rand() % income.length;
        breakPosition = breakPosition ?: 1;
        [source connection:connectionMock didReceiveData:[income subdataWithRange:NSMakeRange(0, breakPosition)]];
        [source connection:connectionMock didReceiveData:[income subdataWithRange:NSMakeRange(breakPosition, income.length - breakPosition)]];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
      });
      
      it(@"should inform about multiply events in one response", ^{
        EventSource *esource = [EventSource eventSourceWithURL:testURL];
        esource.eventSource = connectionMock;
        esource.neverMoveToMain = YES;
        __block NSInteger count = 0;
        validateEvent = ^void(Event *event) {
          [[theValue([event.id integerValue]) should] equal:eventId];
          [[event.data should] equal:eventData];
          if (++count == 2) {
            wasCalled = YES;
            dispatch_semaphore_signal(semaphore);
          }
        };
        [esource addEventListener:@"test event" handler:validateEvent];
        [esource addEventListener:@"other event" handler:validateEvent];
        NSMutableData *income = [[NSMutableData alloc] initWithData:data(@"test event")];
        [income appendData:data(@"other event")];
        [esource connection:connectionMock didReceiveData:income];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
      });
      
    });
    
  });
  
});

SPEC_END
