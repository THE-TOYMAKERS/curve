#import <AppKit/AppKit.h>

// Curve's original mark. Coordinates use a 1024-point, bottom-left origin.
// Build through make-icon.sh; AppKit renders into a bitmap without a window.
static NSColor *color(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}
static void drawIcon(void) {
    NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(48,48,928,928) xRadius:208 yRadius:208];
    NSGradient *field = [[NSGradient alloc] initWithColorsAndLocations:
        color(0.29,0.31,0.75,1),0.0,
        color(0.39,0.47,0.91,1),0.48,
        color(0.60,0.66,1.0,1),1.0,nil];
    [field drawInBezierPath:tile angle:64];
    [NSGraphicsContext saveGraphicsState];
    [tile addClip];
    NSGradient *glow = [[NSGradient alloc] initWithStartingColor:color(0.87,0.91,1,0.25)
                                                  endingColor:color(0.87,0.91,1,0)];
    [glow drawFromCenter:NSMakePoint(300,868) radius:0 toCenter:NSMakePoint(300,868) radius:720 options:NSGradientDrawsAfterEndingLocation];
    [NSGraphicsContext restoreGraphicsState];
    [color(1,1,1,0.22) setStroke];
    tile.lineWidth=2;
    [tile stroke];

    NSBezierPath *curve = [NSBezierPath bezierPath];
    [curve moveToPoint:NSMakePoint(728,716)];
    [curve curveToPoint:NSMakePoint(298,655) controlPoint1:NSMakePoint(615,829) controlPoint2:NSMakePoint(388,812)];
    [curve curveToPoint:NSMakePoint(499,250) controlPoint1:NSMakePoint(203,489) controlPoint2:NSMakePoint(294,265)];
    [curve curveToPoint:NSMakePoint(734,337) controlPoint1:NSMakePoint(588,245) controlPoint2:NSMakePoint(676,277)];
    curve.lineWidth=148;
    curve.lineCapStyle=NSLineCapStyleRound;
    curve.lineJoinStyle=NSLineJoinStyleRound;
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow=[NSShadow new];
    shadow.shadowColor=color(0.12,0.15,0.47,0.27);
    shadow.shadowBlurRadius=22;
    shadow.shadowOffset=NSMakeSize(0,-14);
    [shadow set];
    [color(0.93,0.96,1,1) setStroke];
    [curve stroke];
    [NSGraphicsContext restoreGraphicsState];

    // A white-to-ice ribbon keeps the mark crisp at small sizes.
    CGContextRef context=NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGMutablePathRef path=CGPathCreateMutable();
    CGPathMoveToPoint(path,NULL,728,716);
    CGPathAddCurveToPoint(path,NULL,615,829,388,812,298,655);
    CGPathAddCurveToPoint(path,NULL,203,489,294,265,499,250);
    CGPathAddCurveToPoint(path,NULL,588,245,676,277,734,337);
    CGContextAddPath(context,path);
    CGContextSetLineWidth(context,148);
    CGContextSetLineCap(context,kCGLineCapRound);
    CGContextSetLineJoin(context,kCGLineJoinRound);
    CGContextReplacePathWithStrokedPath(context);
    CGContextClip(context);
    NSGradient *ribbon=[[NSGradient alloc] initWithStartingColor:color(0.81,0.88,1,1) endingColor:color(1,1,1,1)];
    [ribbon drawInRect:NSMakeRect(180,140,660,740) angle:78];
    CGPathRelease(path);
    CGContextRestoreGState(context);
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if(argc!=2) { fprintf(stderr,"Usage: MakeIcon output.png\n"); return 2; }
        NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1024 pixelsHigh:1024 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *context=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext=context;
        CGContextSetInterpolationQuality(context.CGContext,kCGInterpolationHigh);
        drawIcon();
        [context flushGraphics];
        [NSGraphicsContext restoreGraphicsState];
        NSData *data=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSError *error=nil;
        if(![data writeToFile:[NSString stringWithUTF8String:argv[1]] options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1;
        }
    }
    return 0;
}
