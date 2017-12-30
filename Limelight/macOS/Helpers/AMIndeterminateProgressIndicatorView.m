//
//  AMIndeterminateProgressIndicatorCell.m
//  IPICellTest
//
//  Created by Andreas on 23.01.07.
//  Copyright 2007 Andreas Mayer. All rights reserved.
//

//	2007-03-10	Andreas Mayer
//	- removed -keyEquivalent and -keyEquivalentModifierMask methods
//		(I thought those were required by NSTableView/Column. They are not.
//		Instead I was using NSButtons as a container for the cells in the demo project.
//		Replacing those with plain NSControls did fix the problem.)
//	2007-03-24	Andreas Mayer
//	- will now spin in the same direction in flipped and not flipped views
//	2008-09-03	Andreas Mayer
//	- restore default settings for NSBezierPath after drawing
//	- instead of the saturation, we now modify the lines' opacity; does look better on colored
//		backgrounds

#import "AMIndeterminateProgressIndicatorView.h"
#import "math.h"

const CGFloat degreesToRadians = M_PI / 180.0;

@interface AMIndeterminateProgressIndicatorView ()
@property (nonatomic) CGFloat redComponent;
@property (nonatomic) CGFloat greenComponent;
@property (nonatomic) CGFloat blueComponent;
@property (nonatomic) CGFloat tickValue;
@property (nonatomic, strong) NSTimer *heartbeatTimer;
@end

@implementation AMIndeterminateProgressIndicatorView

- (id)init {
	if (self = [super init]) {
        [self setup];
	}
	return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    if (self = [super initWithFrame:frameRect]) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super initWithCoder:coder]) {
        [self setup];
    }
    return self;
}

- (void)dealloc {
    [self.heartbeatTimer invalidate];
}

- (void)setup {
    self.animationDelay = 5.0 / 60.0 / 2;
    self.displayedWhenStopped = NO;
    self.tickValue = 0.0;
    self.color = [NSColor blackColor];
}

- (void)setColor:(NSColor *)value {
	CGFloat alphaComponent;
	if (_color != value) {
		_color = value;
		[[self.color colorUsingColorSpaceName:@"NSCalibratedRGBColorSpace"] getRed:&_redComponent green:&_greenComponent blue:&_blueComponent alpha:&alphaComponent];
		NSAssert((alphaComponent > 0.999), @"color must be opaque");
	}
}

- (void)startAnimation {
    if (self.heartbeatTimer == nil) {
        self.heartbeatTimer = [NSTimer timerWithTimeInterval:self.animationDelay target:self selector:@selector(animate:) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:self.heartbeatTimer forMode:NSRunLoopCommonModes];
        self.spinning = YES;
    }
}

- (void)stopAnimation {
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
    self.spinning = NO;
    [self animate:nil];
}

- (void)animate:(NSTimer *)aTimer {
    if (self.window.isVisible) {
        self.tickValue = fmod((self.tickValue + (5.0/60.0)), 1.0);
        [self setNeedsDisplay:YES];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    [self drawInteriorWithFrame:self.bounds inView:self];
}

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
	if (self.spinning || self.displayedWhenStopped) {
		float flipFactor = ([controlView isFlipped] ? 1.0 : -1.0);
		int step = round(self.tickValue/(5.0/60.0));
		float cellSize = MIN(cellFrame.size.width, cellFrame.size.height);
		NSPoint center = cellFrame.origin;
		center.x += cellSize/2.0;
		center.y += cellFrame.size.height/2.0;
		float outerRadius;
		float innerRadius;
		float strokeWidth = cellSize*0.09;
        outerRadius = cellSize*0.465;
        innerRadius = cellSize*0.27;
		float a; // angle
		NSPoint inner;
		NSPoint outer;
		// remember defaults
		NSLineCapStyle previousLineCapStyle = [NSBezierPath defaultLineCapStyle];
		float previousLineWidth = [NSBezierPath defaultLineWidth]; 
		// new defaults for our loop
		[NSBezierPath setDefaultLineCapStyle:NSRoundLineCapStyle];
		[NSBezierPath setDefaultLineWidth:strokeWidth];
		if (self.spinning) {
			a = (270+(step* 30))*degreesToRadians;
		} else {
			a = 270*degreesToRadians;
		}
		a = flipFactor*a;
		int i;
		for (i = 0; i < 12; i++) {
//			[[NSColor colorWithCalibratedWhite:MIN(sqrt(i)*0.25, 0.8) alpha:1.0] set];
//			[[NSColor colorWithCalibratedWhite:0.0 alpha:1.0-sqrt(i)*0.25] set];
			[[NSColor colorWithCalibratedRed:self.redComponent green:self.greenComponent blue:self.blueComponent alpha:1.0-sqrt(i)*0.25] set];
			outer = NSMakePoint(center.x+cos(a)*outerRadius, center.y+sin(a)*outerRadius);
			inner = NSMakePoint(center.x+cos(a)*innerRadius, center.y+sin(a)*innerRadius);
			[NSBezierPath strokeLineFromPoint:inner toPoint:outer];
			a -= flipFactor*30*degreesToRadians;
		}
		// restore previous defaults
		[NSBezierPath setDefaultLineCapStyle:previousLineCapStyle];
		[NSBezierPath setDefaultLineWidth:previousLineWidth];
	}
}

@end
