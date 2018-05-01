/**
 * Scintilla source code edit control
 * PlatCocoa.mm - implementation of platform facilities on MacOS X/Cocoa
 *
 * Written by Mike Lischke
 * Based on PlatMacOSX.cxx
 * Based on work by Evan Jones (c) 2002 <ejones@uwaterloo.ca>
 * Based on PlatGTK.cxx Copyright 1998-2002 by Neil Hodgson <neilh@scintilla.org>
 * The License.txt file describes the conditions under which this software may be distributed.
 *
 * Copyright 2009 Sun Microsystems, Inc. All rights reserved.
 * This file is dual licensed under LGPL v2.1 and the Scintilla license (http://www.scintilla.org/License.txt).
 */

#include <cstddef>
#include <cstdlib>
#include <cassert>
#include <cstring>
#include <cstdio>

#include <stdexcept>
#include <vector>
#include <map>
#include <memory>

#include <sys/time.h>

#import <Foundation/NSGeometry.h>

#import "Platform.h"

#include "StringCopy.h"
#include "XPM.h"
#include "UniConversion.h"

#import "ScintillaView.h"
#import "ScintillaCocoa.h"
#import "PlatCocoa.h"

using namespace Scintilla;

extern sptr_t scintilla_send_message(void* sci, unsigned int iMessage, uptr_t wParam, sptr_t lParam);

//--------------------------------------------------------------------------------------------------

/**
 * Converts a PRectangle as used by Scintilla to standard Obj-C NSRect structure .
 */
NSRect PRectangleToNSRect(const PRectangle& rc)
{
  return NSMakeRect(rc.left, rc.top, rc.Width(), rc.Height());
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts an NSRect as used by the system to a native Scintilla rectangle.
 */
PRectangle NSRectToPRectangle(NSRect& rc)
{
  return PRectangle(static_cast<XYPOSITION>(rc.origin.x), static_cast<XYPOSITION>(rc.origin.y),
					static_cast<XYPOSITION>(NSMaxX(rc)),
					static_cast<XYPOSITION>(NSMaxY(rc)));
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts a PRectangle as used by Scintilla to a Quartz-style rectangle.
 */
inline CGRect PRectangleToCGRect(PRectangle& rc)
{
  return CGRectMake(rc.left, rc.top, rc.Width(), rc.Height());
}

//----------------- Font ---------------------------------------------------------------------------

Font::Font(): fid(0)
{
}

//--------------------------------------------------------------------------------------------------

Font::~Font()
{
  Release();
}

//--------------------------------------------------------------------------------------------------

static QuartzTextStyle *TextStyleFromFont(Font &f) {
	return static_cast<QuartzTextStyle *>(f.GetID());
}

//--------------------------------------------------------------------------------------------------

static int FontCharacterSet(Font &f) {
	return TextStyleFromFont(f)->getCharacterSet();
}

//--------------------------------------------------------------------------------------------------

/**
 * Creates a CTFontRef with the given properties.
 */
void Font::Create(const FontParameters &fp)
{
	Release();

	QuartzTextStyle* style = new QuartzTextStyle();
	fid = style;

	// Create the font with attributes
	QuartzFont font(fp.faceName, strlen(fp.faceName), fp.size, fp.weight, fp.italic);
	CTFontRef fontRef = font.getFontID();
	style->setFontRef(fontRef, fp.characterSet);
}

//--------------------------------------------------------------------------------------------------

void Font::Release()
{
  if (fid)
    delete static_cast<QuartzTextStyle*>( fid );
  fid = 0;
}

//----------------- SurfaceImpl --------------------------------------------------------------------

SurfaceImpl::SurfaceImpl()
{
  unicodeMode = true;
  x = 0;
  y = 0;
  gc = NULL;

  textLayout.reset(new QuartzTextLayout(nullptr));
  codePage = 0;
  verticalDeviceResolution = 0;

  bitmapData.reset(); // Release will try and delete bitmapData if != nullptr
  bitmapWidth = 0;
  bitmapHeight = 0;

  Release();
}

//--------------------------------------------------------------------------------------------------

SurfaceImpl::~SurfaceImpl()
{
  Clear();
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Clear()
{
  textLayout->setContext(nullptr);
  if (bitmapData)
  {
    bitmapData.reset();
    // We only "own" the graphics context if we are a bitmap context
    if (gc)
      CGContextRelease(gc);
  }
  gc = NULL;

  bitmapWidth = 0;
  bitmapHeight = 0;
  x = 0;
  y = 0;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Release() {
	Clear();
}

//--------------------------------------------------------------------------------------------------

bool SurfaceImpl::Initialised()
{
  // We are initalised if the graphics context is not null
  return gc != NULL;// || port != NULL;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Init(WindowID)
{
  // To be able to draw, the surface must get a CGContext handle.  We save the graphics port,
  // then acquire/release the context on an as-need basis (see above).
  // XXX Docs on QDBeginCGContext are light, a better way to do this would be good.
  // AFAIK we should not hold onto a context retrieved this way, thus the need for
  // acquire/release of the context.

  Release();
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Init(SurfaceID sid, WindowID)
{
  Release();
  gc = static_cast<CGContextRef>(sid);
  CGContextSetLineWidth(gc, 1.0);
  textLayout->setContext(gc);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::InitPixMap(int width, int height, Surface* surface_, WindowID /* wid */)
{
  Release();

  // Create a new bitmap context, along with the RAM for the bitmap itself
  bitmapWidth = width;
  bitmapHeight = height;

  const int bitmapBytesPerRow = (width * BYTES_PER_PIXEL);
  const int bitmapByteCount = (bitmapBytesPerRow * height);

  // Create an RGB color space.
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  if (colorSpace == NULL)
    return;

  // Create the bitmap.
  bitmapData.reset(new uint8_t[bitmapByteCount]);
  // create the context
  gc = CGBitmapContextCreate(bitmapData.get(),
                             width,
                             height,
                             BITS_PER_COMPONENT,
                             bitmapBytesPerRow,
                             colorSpace,
                             kCGImageAlphaPremultipliedLast);

  if (gc == NULL)
  {
    // the context couldn't be created for some reason,
    // and we have no use for the bitmap without the context
    bitmapData.reset();
  }
  textLayout->setContext (gc);

  // the context retains the color space, so we can release it
  CGColorSpaceRelease(colorSpace);

  if (gc && bitmapData)
  {
    // "Erase" to white.
    CGContextClearRect( gc, CGRectMake( 0, 0, width, height ) );
    CGContextSetRGBFillColor( gc, 1.0, 1.0, 1.0, 1.0 );
    CGContextFillRect( gc, CGRectMake( 0, 0, width, height ) );
  }

  if (surface_)
  {
    SurfaceImpl *psurfOther = static_cast<SurfaceImpl *>(surface_);
    unicodeMode = psurfOther->unicodeMode;
    codePage = psurfOther->codePage;
  }
  else
  {
    unicodeMode = true;
    codePage = SC_CP_UTF8;
  }
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::PenColour(ColourDesired fore)
{
  if (gc)
  {
    ColourDesired colour(fore.AsLong());

    // Set the Stroke color to match
    CGContextSetRGBStrokeColor(gc, colour.GetRed() / 255.0, colour.GetGreen() / 255.0,
                               colour.GetBlue() / 255.0, 1.0 );
  }
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::FillColour(const ColourDesired& back)
{
  if (gc)
  {
    ColourDesired colour(back.AsLong());

    // Set the Fill color to match
    CGContextSetRGBFillColor(gc, colour.GetRed() / 255.0, colour.GetGreen() / 255.0,
                             colour.GetBlue() / 255.0, 1.0 );
  }
}

//--------------------------------------------------------------------------------------------------

CGImageRef SurfaceImpl::GetImage()
{
  // For now, assume that GetImage can only be called on PixMap surfaces.
  if (!bitmapData)
    return NULL;

  CGContextFlush(gc);

  // Create an RGB color space.
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  if( colorSpace == NULL )
    return NULL;

  const int bitmapBytesPerRow = bitmapWidth * BYTES_PER_PIXEL;
  const int bitmapByteCount = bitmapBytesPerRow * bitmapHeight;

  // Make a copy of the bitmap data for the image creation and divorce it
  // From the SurfaceImpl lifetime
  CFDataRef dataRef = CFDataCreate(kCFAllocatorDefault, bitmapData.get(), bitmapByteCount);

  // Create a data provider.
  CGDataProviderRef dataProvider = CGDataProviderCreateWithCFData(dataRef);

  CGImageRef image = NULL;
  if (dataProvider != NULL)
  {
    // Create the CGImage.
    image = CGImageCreate(bitmapWidth,
                          bitmapHeight,
                          BITS_PER_COMPONENT,
                          BITS_PER_PIXEL,
                          bitmapBytesPerRow,
                          colorSpace,
                          kCGImageAlphaPremultipliedLast,
                          dataProvider,
                          NULL,
                          0,
                          kCGRenderingIntentDefault);
  }

  // The image retains the color space, so we can release it.
  CGColorSpaceRelease(colorSpace);
  colorSpace = NULL;

  // Done with the data provider.
  CGDataProviderRelease(dataProvider);
  dataProvider = NULL;

  // Done with the data provider.
  CFRelease(dataRef);

  return image;
}

//--------------------------------------------------------------------------------------------------

/**
 * Returns the vertical logical device resolution of the main monitor.
 * This is no longer called.
 * For Cocoa, all screens are treated as 72 DPI, even retina displays.
 */
int SurfaceImpl::LogPixelsY()
{
  return 72;
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts the logical font height in points into a device height.
 * For Cocoa, points are always used for the result even on retina displays.
 */
int SurfaceImpl::DeviceHeightFont(int points)
{
  return points;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::MoveTo(int x_, int y_)
{
  x = x_;
  y = y_;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::LineTo(int x_, int y_)
{
  CGContextBeginPath( gc );

  // Because Quartz is based on floating point, lines are drawn with half their colour
  // on each side of the line. Integer coordinates specify the INTERSECTION of the pixel
  // division lines. If you specify exact pixel values, you get a line that
  // is twice as thick but half as intense. To get pixel aligned rendering,
  // we render the "middle" of the pixels by adding 0.5 to the coordinates.
  CGContextMoveToPoint( gc, x + 0.5, y + 0.5 );
  CGContextAddLineToPoint( gc, x_ + 0.5, y_ + 0.5 );
  CGContextStrokePath( gc );
  x = x_;
  y = y_;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::Polygon(Scintilla::Point *pts, int npts, ColourDesired fore,
                          ColourDesired back)
{
  // Allocate memory for the array of points.
  std::vector<CGPoint> points(npts);

  for (int i = 0;i < npts;i++)
  {
    // Quartz floating point issues: plot the MIDDLE of the pixels
    points[i].x = pts[i].x + 0.5;
    points[i].y = pts[i].y + 0.5;
  }

  CGContextBeginPath(gc);

  // Set colours
  FillColour(back);
  PenColour(fore);

  // Draw the polygon
  CGContextAddLines(gc, points.data(), npts);

  // Explicitly close the path, so it is closed for stroking AND filling (implicit close = filling only)
  CGContextClosePath( gc );
  CGContextDrawPath( gc, kCGPathFillStroke );
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::RectangleDraw(PRectangle rc, ColourDesired fore, ColourDesired back)
{
  if (gc)
  {
    CGContextBeginPath( gc );
    FillColour(back);
    PenColour(fore);

    // Quartz integer -> float point conversion fun (see comment in SurfaceImpl::LineTo)
    // We subtract 1 from the Width() and Height() so that all our drawing is within the area defined
    // by the PRectangle. Otherwise, we draw one pixel too far to the right and bottom.
    CGContextAddRect( gc, CGRectMake( rc.left + 0.5, rc.top + 0.5, rc.Width() - 1, rc.Height() - 1 ) );
    CGContextDrawPath( gc, kCGPathFillStroke );
  }
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::FillRectangle(PRectangle rc, ColourDesired back)
{
  if (gc)
  {
    FillColour(back);
    // Snap rectangle boundaries to nearest int
    rc.left = lround(rc.left);
    rc.right = lround(rc.right);
    CGRect rect = PRectangleToCGRect(rc);
    CGContextFillRect(gc, rect);
  }
}

//--------------------------------------------------------------------------------------------------

static void drawImageRefCallback(void *info, CGContextRef gc)
{
  CGImageRef pattern = static_cast<CGImageRef>(info);
  CGContextDrawImage(gc, CGRectMake(0, 0, CGImageGetWidth(pattern), CGImageGetHeight(pattern)), pattern);
}

//--------------------------------------------------------------------------------------------------

static void releaseImageRefCallback(void *info)
{
  CGImageRelease(static_cast<CGImageRef>(info));
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::FillRectangle(PRectangle rc, Surface &surfacePattern)
{
  SurfaceImpl& patternSurface = static_cast<SurfaceImpl &>(surfacePattern);

  // For now, assume that copy can only be called on PixMap surfaces. Shows up black.
  CGImageRef image = patternSurface.GetImage();
  if (image == NULL)
  {
    FillRectangle(rc, ColourDesired(0));
    return;
  }

  const CGPatternCallbacks drawImageCallbacks = { 0, drawImageRefCallback, releaseImageRefCallback };

  CGPatternRef pattern = CGPatternCreate(image,
                                         CGRectMake(0, 0, patternSurface.bitmapWidth, patternSurface.bitmapHeight),
                                         CGAffineTransformIdentity,
                                         patternSurface.bitmapWidth,
                                         patternSurface.bitmapHeight,
                                         kCGPatternTilingNoDistortion,
                                         true,
                                         &drawImageCallbacks
                                        );
  if (pattern != NULL)
  {
    // Create a pattern color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreatePattern( NULL );
    if( colorSpace != NULL ) {

      CGContextSaveGState( gc );
      CGContextSetFillColorSpace( gc, colorSpace );

      // Unlike the documentation, you MUST pass in a "components" parameter:
      // For coloured patterns it is the alpha value.
      const CGFloat alpha = 1.0;
      CGContextSetFillPattern( gc, pattern, &alpha );
      CGContextFillRect( gc, PRectangleToCGRect( rc ) );
      CGContextRestoreGState( gc );
      // Free the color space, the pattern and image
      CGColorSpaceRelease( colorSpace );
    } /* colorSpace != NULL */
    colorSpace = NULL;
    CGPatternRelease( pattern );
    pattern = NULL;
  } /* pattern != NULL */
}

void SurfaceImpl::RoundedRectangle(PRectangle rc, ColourDesired fore, ColourDesired back) {
  // This is only called from the margin marker drawing code for SC_MARK_ROUNDRECT
  // The Win32 version does
  //  ::RoundRect(hdc, rc.left + 1, rc.top, rc.right - 1, rc.bottom, 8, 8 );
  // which is a rectangle with rounded corners each having a radius of 4 pixels.
  // It would be almost as good just cutting off the corners with lines at
  // 45 degrees as is done on GTK+.

  // Create a rectangle with semicircles at the corners
  const int MAX_RADIUS = 4;
  const int radius = std::min(MAX_RADIUS, static_cast<int>(std::min(rc.Height()/2, rc.Width()/2)));

  // Points go clockwise, starting from just below the top left
  // Corners are kept together, so we can easily create arcs to connect them
  CGPoint corners[4][3] =
  {
    {
      { rc.left, rc.top + radius },
      { rc.left, rc.top },
      { rc.left + radius, rc.top },
    },
    {
      { rc.right - radius - 1, rc.top },
      { rc.right - 1, rc.top },
      { rc.right - 1, rc.top + radius },
    },
    {
      { rc.right - 1, rc.bottom - radius - 1 },
      { rc.right - 1, rc.bottom - 1 },
      { rc.right - radius - 1, rc.bottom - 1 },
    },
    {
      { rc.left + radius, rc.bottom - 1 },
      { rc.left, rc.bottom - 1 },
      { rc.left, rc.bottom - radius - 1 },
    },
  };

  // Align the points in the middle of the pixels
  for( int i = 0; i < 4; ++ i )
  {
    for( int j = 0; j < 3; ++ j )
    {
      corners[i][j].x += 0.5;
      corners[i][j].y += 0.5;
    }
  }

  PenColour( fore );
  FillColour( back );

  // Move to the last point to begin the path
  CGContextBeginPath( gc );
  CGContextMoveToPoint( gc, corners[3][2].x, corners[3][2].y );

  for ( int i = 0; i < 4; ++ i )
  {
    CGContextAddLineToPoint( gc, corners[i][0].x, corners[i][0].y );
    CGContextAddArcToPoint( gc, corners[i][1].x, corners[i][1].y, corners[i][2].x, corners[i][2].y, radius );
  }

  // Close the path to enclose it for stroking and for filling, then draw it
  CGContextClosePath( gc );
  CGContextDrawPath( gc, kCGPathFillStroke );
}

// DrawChamferedRectangle is a helper function for AlphaRectangle that either fills or strokes a
// rectangle with its corners chamfered at 45 degrees.
static void DrawChamferedRectangle(CGContextRef gc, PRectangle rc, int cornerSize, CGPathDrawingMode mode) {
  // Points go clockwise, starting from just below the top left
  CGPoint corners[4][2] =
  {
    {
      { rc.left, rc.top + cornerSize },
      { rc.left + cornerSize, rc.top },
    },
    {
      { rc.right - cornerSize - 1, rc.top },
      { rc.right - 1, rc.top + cornerSize },
    },
    {
      { rc.right - 1, rc.bottom - cornerSize - 1 },
      { rc.right - cornerSize - 1, rc.bottom - 1 },
    },
    {
      { rc.left + cornerSize, rc.bottom - 1 },
      { rc.left, rc.bottom - cornerSize - 1 },
    },
  };

  // Align the points in the middle of the pixels
  for( int i = 0; i < 4; ++ i )
  {
    for( int j = 0; j < 2; ++ j )
    {
      corners[i][j].x += 0.5;
      corners[i][j].y += 0.5;
    }
  }

  // Move to the last point to begin the path
  CGContextBeginPath( gc );
  CGContextMoveToPoint( gc, corners[3][1].x, corners[3][1].y );

  for ( int i = 0; i < 4; ++ i )
  {
    CGContextAddLineToPoint( gc, corners[i][0].x, corners[i][0].y );
    CGContextAddLineToPoint( gc, corners[i][1].x, corners[i][1].y );
  }

  // Close the path to enclose it for stroking and for filling, then draw it
  CGContextClosePath( gc );
  CGContextDrawPath( gc, mode );
}

void Scintilla::SurfaceImpl::AlphaRectangle(PRectangle rc, int cornerSize, ColourDesired fill, int alphaFill,
                                            ColourDesired outline, int alphaOutline, int /*flags*/)
{
  if ( gc ) {
    // Snap rectangle boundaries to nearest int
    rc.left = lround(rc.left);
    rc.right = lround(rc.right);
    // Set the Fill color to match
    CGContextSetRGBFillColor( gc, fill.GetRed() / 255.0, fill.GetGreen() / 255.0, fill.GetBlue() / 255.0, alphaFill / 255.0 );
    CGContextSetRGBStrokeColor( gc, outline.GetRed() / 255.0, outline.GetGreen() / 255.0, outline.GetBlue() / 255.0, alphaOutline / 255.0 );
    PRectangle rcFill = rc;
    if (cornerSize == 0) {
      // A simple rectangle, no rounded corners
      if ((fill == outline) && (alphaFill == alphaOutline)) {
        // Optimization for simple case
        CGRect rect = PRectangleToCGRect( rcFill );
        CGContextFillRect( gc, rect );
      } else {
        rcFill.left += 1.0;
        rcFill.top += 1.0;
        rcFill.right -= 1.0;
        rcFill.bottom -= 1.0;
        CGRect rect = PRectangleToCGRect( rcFill );
        CGContextFillRect( gc, rect );
        CGContextAddRect( gc, CGRectMake( rc.left + 0.5, rc.top + 0.5, rc.Width() - 1, rc.Height() - 1 ) );
        CGContextStrokePath( gc );
      }
    } else {
      // Approximate rounded corners with 45 degree chamfers.
      // Drawing real circular arcs often leaves some over- or under-drawn pixels.
      if ((fill == outline) && (alphaFill == alphaOutline)) {
        // Specializing this case avoids a few stray light/dark pixels in corners.
        rcFill.left -= 0.5;
        rcFill.top -= 0.5;
        rcFill.right += 0.5;
        rcFill.bottom += 0.5;
        DrawChamferedRectangle( gc, rcFill, cornerSize, kCGPathFill );
      } else {
        rcFill.left += 0.5;
        rcFill.top += 0.5;
        rcFill.right -= 0.5;
        rcFill.bottom -= 0.5;
        DrawChamferedRectangle( gc, rcFill, cornerSize-1, kCGPathFill );
        DrawChamferedRectangle( gc, rc, cornerSize, kCGPathStroke );
      }
    }
  }
}

static void ProviderReleaseData(void *, const void *data, size_t) {
	const unsigned char *pixels = static_cast<const unsigned char *>(data);
	delete []pixels;
}

static CGImageRef ImageCreateFromRGBA(int width, int height, const unsigned char *pixelsImage, bool invert) {
	CGImageRef image = 0;

	// Create an RGB color space.
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	if (colorSpace) {
		const int bitmapBytesPerRow = width * 4;
		const int bitmapByteCount = bitmapBytesPerRow * height;

		// Create a data provider.
		CGDataProviderRef dataProvider = 0;
		if (invert) {
			unsigned char *pixelsUpsideDown = new unsigned char[bitmapByteCount];

			for (int y=0; y<height; y++) {
				int yInverse = height - y - 1;
				memcpy(pixelsUpsideDown + y * bitmapBytesPerRow,
				       pixelsImage + yInverse * bitmapBytesPerRow,
				       bitmapBytesPerRow);
			}

			dataProvider = CGDataProviderCreateWithData(
								NULL, pixelsUpsideDown, bitmapByteCount, ProviderReleaseData);
		} else {
			dataProvider = CGDataProviderCreateWithData(
								NULL, pixelsImage, bitmapByteCount, NULL);

		}
		if (dataProvider) {
			// Create the CGImage.
			image = CGImageCreate(width,
							 height,
							 8,
							 8 * 4,
							 bitmapBytesPerRow,
							 colorSpace,
							 kCGImageAlphaLast,
							 dataProvider,
							 NULL,
							 0,
							 kCGRenderingIntentDefault);

			CGDataProviderRelease(dataProvider);
		}

		// The image retains the color space, so we can release it.
		CGColorSpaceRelease(colorSpace);
	}
	return image;
}

void SurfaceImpl::DrawRGBAImage(PRectangle rc, int width, int height, const unsigned char *pixelsImage) {
	CGImageRef image = ImageCreateFromRGBA(width, height, pixelsImage, true);
	if (image) {
		CGRect drawRect = CGRectMake(rc.left, rc.top, rc.Width(), rc.Height());
		CGContextDrawImage(gc, drawRect, image);
		CGImageRelease(image);
	}
}

void SurfaceImpl::Ellipse(PRectangle rc, ColourDesired fore, ColourDesired back) {
  CGRect ellipseRect = CGRectMake(rc.left, rc.top, rc.Width(), rc.Height());
  FillColour(back);
  PenColour(fore);
  CGContextBeginPath(gc);
  CGContextAddEllipseInRect(gc, ellipseRect);
  CGContextDrawPath(gc, kCGPathFillStroke);
}

void SurfaceImpl::CopyImageRectangle(Surface &surfaceSource, PRectangle srcRect, PRectangle dstRect)
{
  SurfaceImpl& source = static_cast<SurfaceImpl &>(surfaceSource);
  CGImageRef image = source.GetImage();

  CGRect src = PRectangleToCGRect(srcRect);
  CGRect dst = PRectangleToCGRect(dstRect);

  /* source from QuickDrawToQuartz2D.pdf on developer.apple.com */
  const float w = static_cast<float>(CGImageGetWidth(image));
  const float h = static_cast<float>(CGImageGetHeight(image));
  CGRect drawRect = CGRectMake (0, 0, w, h);
  if (!CGRectEqualToRect (src, dst))
  {
    CGFloat sx = CGRectGetWidth(dst) / CGRectGetWidth(src);
    CGFloat sy = CGRectGetHeight(dst) / CGRectGetHeight(src);
    CGFloat dx = CGRectGetMinX(dst) - (CGRectGetMinX(src) * sx);
    CGFloat dy = CGRectGetMinY(dst) - (CGRectGetMinY(src) * sy);
    drawRect = CGRectMake (dx, dy, w*sx, h*sy);
  }
  CGContextSaveGState (gc);
  CGContextClipToRect (gc, dst);
  CGContextDrawImage (gc, drawRect, image);
  CGContextRestoreGState (gc);
  CGImageRelease(image);
}

void SurfaceImpl::Copy(PRectangle rc, Scintilla::Point from, Surface &surfaceSource) {
  // Maybe we have to make the Surface two contexts:
  // a bitmap context which we do all the drawing on, and then a "real" context
  // which we copy the output to when we call "Synchronize". Ugh! Gross and slow!

  // For now, assume that copy can only be called on PixMap surfaces
  SurfaceImpl& source = static_cast<SurfaceImpl &>(surfaceSource);

  // Get the CGImageRef
  CGImageRef image = source.GetImage();
  // If we could not get an image reference, fill the rectangle black
  if ( image == NULL )
  {
    FillRectangle( rc, ColourDesired( 0 ) );
    return;
  }

  // Now draw the image on the surface

  // Some fancy clipping work is required here: draw only inside of rc
  CGContextSaveGState( gc );
  CGContextClipToRect( gc, PRectangleToCGRect( rc ) );

  //Platform::DebugPrintf(stderr, "Copy: CGContextDrawImage: (%d, %d) - (%d X %d)\n", rc.left - from.x, rc.top - from.y, source.bitmapWidth, source.bitmapHeight );
  CGContextDrawImage( gc, CGRectMake( rc.left - from.x, rc.top - from.y, source.bitmapWidth, source.bitmapHeight ), image );

  // Undo the clipping fun
  CGContextRestoreGState( gc );

  // Done with the image
  CGImageRelease( image );
  image = NULL;
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::DrawTextNoClip(PRectangle rc, Font &font_, XYPOSITION ybase, const char *s, int len,
                                 ColourDesired fore, ColourDesired back)
{
  FillRectangle(rc, back);
  DrawTextTransparent(rc, font_, ybase, s, len, fore);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::DrawTextClipped(PRectangle rc, Font &font_, XYPOSITION ybase, const char *s, int len,
                                  ColourDesired fore, ColourDesired back)
{
  CGContextSaveGState(gc);
  CGContextClipToRect(gc, PRectangleToCGRect(rc));
  DrawTextNoClip(rc, font_, ybase, s, len, fore, back);
  CGContextRestoreGState(gc);
}

//--------------------------------------------------------------------------------------------------

CFStringEncoding EncodingFromCharacterSet(bool unicode, int characterSet)
{
  if (unicode)
    return kCFStringEncodingUTF8;

  // Unsupported -> Latin1 as reasonably safe
  enum { notSupported = kCFStringEncodingISOLatin1};

  switch (characterSet)
  {
  case SC_CHARSET_ANSI:
    return kCFStringEncodingISOLatin1;
  case SC_CHARSET_DEFAULT:
    return kCFStringEncodingISOLatin1;
  case SC_CHARSET_BALTIC:
    return kCFStringEncodingWindowsBalticRim;
  case SC_CHARSET_CHINESEBIG5:
    return kCFStringEncodingBig5;
  case SC_CHARSET_EASTEUROPE:
    return kCFStringEncodingWindowsLatin2;
  case SC_CHARSET_GB2312:
    return kCFStringEncodingGB_18030_2000;
  case SC_CHARSET_GREEK:
    return kCFStringEncodingWindowsGreek;
  case SC_CHARSET_HANGUL:
    return kCFStringEncodingEUC_KR;
  case SC_CHARSET_MAC:
    return kCFStringEncodingMacRoman;
  case SC_CHARSET_OEM:
    return kCFStringEncodingISOLatin1;
  case SC_CHARSET_RUSSIAN:
    return kCFStringEncodingKOI8_R;
  case SC_CHARSET_CYRILLIC:
    return kCFStringEncodingWindowsCyrillic;
  case SC_CHARSET_SHIFTJIS:
    return kCFStringEncodingShiftJIS;
  case SC_CHARSET_SYMBOL:
    return kCFStringEncodingMacSymbol;
  case SC_CHARSET_TURKISH:
    return kCFStringEncodingWindowsLatin5;
  case SC_CHARSET_JOHAB:
    return kCFStringEncodingWindowsKoreanJohab;
  case SC_CHARSET_HEBREW:
    return kCFStringEncodingWindowsHebrew;
  case SC_CHARSET_ARABIC:
    return kCFStringEncodingWindowsArabic;
  case SC_CHARSET_VIETNAMESE:
    return kCFStringEncodingWindowsVietnamese;
  case SC_CHARSET_THAI:
    return kCFStringEncodingISOLatinThai;
  case SC_CHARSET_8859_15:
    return kCFStringEncodingISOLatin1;
  default:
    return notSupported;
  }
}

void SurfaceImpl::DrawTextTransparent(PRectangle rc, Font &font_, XYPOSITION ybase, const char *s, int len,
                                      ColourDesired fore)
{
	CFStringEncoding encoding = EncodingFromCharacterSet(unicodeMode, FontCharacterSet(font_));
	ColourDesired colour(fore.AsLong());
	CGColorRef color = CGColorCreateGenericRGB(colour.GetRed()/255.0,colour.GetGreen()/255.0,colour.GetBlue()/255.0,1.0);

	QuartzTextStyle *style = TextStyleFromFont(font_);
	style->setCTStyleColor(color);

	CGColorRelease(color);

	textLayout->setText(s, len, encoding, *style);
	textLayout->draw(rc.left, ybase);
}

//--------------------------------------------------------------------------------------------------

void SurfaceImpl::MeasureWidths(Font &font_, const char *s, int len, XYPOSITION *positions)
{
	CFStringEncoding encoding = EncodingFromCharacterSet(unicodeMode, FontCharacterSet(font_));
	textLayout->setText(s, len, encoding, *TextStyleFromFont(font_));

	CTLineRef mLine = textLayout->getCTLine();
	assert(mLine != NULL);

	if (unicodeMode) {
		// Map the widths given for UTF-16 characters back onto the UTF-8 input string
		CFIndex fit = textLayout->getStringLength();
		int ui=0;
		int i=0;
		while (ui<fit) {
			const unsigned char uch = s[i];
			const unsigned int byteCount = UTF8BytesOfLead[uch];
			const int codeUnits = UTF16LengthFromUTF8ByteCount(byteCount);
			CGFloat xPosition = CTLineGetOffsetForStringIndex(mLine, ui+codeUnits, NULL);
			for (unsigned int bytePos=0; (bytePos<byteCount) && (i<len); bytePos++) {
				positions[i++] = static_cast<XYPOSITION>(xPosition);
			}
			ui += codeUnits;
		}
		XYPOSITION lastPos = 0.0f;
		if (i > 0)
			lastPos = positions[i-1];
		while (i<len) {
			positions[i++] = lastPos;
		}
	} else if (codePage) {
		int ui = 0;
		for (int i=0;i<len;) {
			size_t lenChar = DBCSIsLeadByte(codePage, s[i]) ? 2 : 1;
			CGFloat xPosition = CTLineGetOffsetForStringIndex(mLine, ui+1, NULL);
			for (unsigned int bytePos=0; (bytePos<lenChar) && (i<len); bytePos++) {
				positions[i++] = static_cast<XYPOSITION>(xPosition);
			}
			ui++;
		}
	} else {	// Single byte encoding
		for (int i=0;i<len;i++) {
			CGFloat xPosition = CTLineGetOffsetForStringIndex(mLine, i+1, NULL);
			positions[i] = static_cast<XYPOSITION>(xPosition);
		}
	}

}

XYPOSITION SurfaceImpl::WidthText(Font &font_, const char *s, int len) {
  if (font_.GetID())
  {
    CFStringEncoding encoding = EncodingFromCharacterSet(unicodeMode, FontCharacterSet(font_));
		textLayout->setText(s, len, encoding, *TextStyleFromFont(font_));

	return static_cast<XYPOSITION>(textLayout->MeasureStringWidth());
  }
  return 1;
}

XYPOSITION SurfaceImpl::WidthChar(Font &font_, char ch) {
  char str[2] = { ch, '\0' };
  if (font_.GetID())
  {
    CFStringEncoding encoding = EncodingFromCharacterSet(unicodeMode, FontCharacterSet(font_));
		textLayout->setText(str, 1, encoding, *TextStyleFromFont(font_));

    return textLayout->MeasureStringWidth();
  }
  else
    return 1;
}

// This string contains a good range of characters to test for size.
const char sizeString[] = "`~!@#$%^&*()-_=+\\|[]{};:\"\'<,>.?/1234567890"
"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

XYPOSITION SurfaceImpl::Ascent(Font &font_) {
  if (!font_.GetID())
    return 1;

	float ascent = TextStyleFromFont(font_)->getAscent();
	return ascent + 0.5f;

}

XYPOSITION SurfaceImpl::Descent(Font &font_) {
  if (!font_.GetID())
    return 1;

	float descent = TextStyleFromFont(font_)->getDescent();
	return descent + 0.5f;

}

XYPOSITION SurfaceImpl::InternalLeading(Font &) {
  return 0;
}

XYPOSITION SurfaceImpl::Height(Font &font_) {

	return Ascent(font_) + Descent(font_);
}

XYPOSITION SurfaceImpl::AverageCharWidth(Font &font_) {

  if (!font_.GetID())
    return 1;

  const int sizeStringLength = ELEMENTS( sizeString );
  XYPOSITION width = WidthText( font_, sizeString, sizeStringLength  );

  return round(width / sizeStringLength);
}

void SurfaceImpl::SetClip(PRectangle rc) {
  CGContextClipToRect( gc, PRectangleToCGRect( rc ) );
}

void SurfaceImpl::FlushCachedState() {
  CGContextSynchronize( gc );
}

void SurfaceImpl::SetUnicodeMode(bool unicodeMode_) {
  unicodeMode = unicodeMode_;
}

void SurfaceImpl::SetDBCSMode(int codePage_) {
  if (codePage_ && (codePage_ != SC_CP_UTF8))
    codePage = codePage_;
}

Surface *Surface::Allocate(int)
{
  return new SurfaceImpl();
}

//----------------- Window -------------------------------------------------------------------------

// Cocoa uses different types for windows and views, so a Window may
// be either an NSWindow or NSView and the code will check the type
// before performing an action.

Window::~Window()
{
}

// Window::Destroy needs to see definition of ListBoxImpl so is located after ListBoxImpl

//--------------------------------------------------------------------------------------------------

static CGFloat ScreenMax()
{
  return NSMaxY([[NSScreen mainScreen] frame]);
}

//--------------------------------------------------------------------------------------------------

PRectangle Window::GetPosition()
{
  if (wid)
  {
    NSRect rect;
    id idWin = static_cast<id>(wid);
    NSWindow* win;
    if ([idWin isKindOfClass: [NSView class]])
    {
      // NSView
      NSView* view = idWin;
      win = [view window];
      rect = [view convertRect: [view bounds] toView: nil];
      rect = [win convertRectToScreen:rect];
    }
    else
    {
      // NSWindow
      win = idWin;
      rect = [win frame];
    }
    CGFloat screenHeight = ScreenMax();
    // Invert screen positions to match Scintilla
    return PRectangle(
        static_cast<XYPOSITION>(NSMinX(rect)), static_cast<XYPOSITION>(screenHeight - NSMaxY(rect)),
        static_cast<XYPOSITION>(NSMaxX(rect)), static_cast<XYPOSITION>(screenHeight - NSMinY(rect)));
  }
  else
  {
    return PRectangle(0, 0, 1, 1);
  }
}

//--------------------------------------------------------------------------------------------------

void Window::SetPosition(PRectangle rc)
{
  if (wid)
  {
    id idWin = static_cast<id>(wid);
    if ([idWin isKindOfClass: [NSView class]])
    {
      // NSView
      // Moves this view inside the parent view
      NSRect nsrc = NSMakeRect(rc.left, rc.bottom, rc.Width(), rc.Height());
      NSView* view = idWin;
      nsrc = [[view window] convertRectFromScreen:nsrc];
      [view setFrame: nsrc];
    }
    else
    {
      // NSWindow
      PLATFORM_ASSERT([idWin isKindOfClass: [NSWindow class]]);
      NSWindow* win = idWin;
      CGFloat screenHeight = ScreenMax();
      NSRect nsrc = NSMakeRect(rc.left, screenHeight - rc.bottom,
          rc.Width(), rc.Height());
      [win setFrame: nsrc display:YES];
    }
  }
}

//--------------------------------------------------------------------------------------------------

void Window::SetPositionRelative(PRectangle rc, Window window)
{
  PRectangle rcOther = window.GetPosition();
  rc.left += rcOther.left;
  rc.right += rcOther.left;
  rc.top += rcOther.top;
  rc.bottom += rcOther.top;
  SetPosition(rc);
}

//--------------------------------------------------------------------------------------------------

PRectangle Window::GetClientPosition()
{
  // This means, in MacOS X terms, get the "frame bounds". Call GetPosition, just like on Win32.
  return GetPosition();
}

//--------------------------------------------------------------------------------------------------

void Window::Show(bool show)
{
  if (wid)
  {
    id idWin = static_cast<id>(wid);
    if ([idWin isKindOfClass: [NSWindow class]])
    {
      NSWindow* win = idWin;
      if (show)
      {
        [win orderFront:nil];
      }
      else
      {
        [win orderOut:nil];
      }
    }
  }
}

//--------------------------------------------------------------------------------------------------

/**
 * Invalidates the entire window or view so it is completely redrawn.
 */
void Window::InvalidateAll()
{
  if (wid)
  {
    id idWin = static_cast<id>(wid);
    NSView* container;
    if ([idWin isKindOfClass: [NSView class]])
    {
      container = idWin;
    }
    else
    {
      // NSWindow
      NSWindow* win = idWin;
      container = [win contentView];
      container.needsDisplay = YES;
    }
    container.needsDisplay = YES;
  }
}

//--------------------------------------------------------------------------------------------------

/**
 * Invalidates part of the window or view so only this part redrawn.
 */
void Window::InvalidateRectangle(PRectangle rc)
{
  if (wid)
  {
    id idWin = static_cast<id>(wid);
    NSView* container;
    if ([idWin isKindOfClass: [NSView class]])
    {
      container = idWin;
    }
    else
    {
      // NSWindow
      NSWindow* win = idWin;
      container = [win contentView];
    }
    [container setNeedsDisplayInRect: PRectangleToNSRect(rc)];
  }
}

//--------------------------------------------------------------------------------------------------

void Window::SetFont(Font&)
{
  // Implemented on list subclass on Cocoa.
}

//--------------------------------------------------------------------------------------------------

/**
 * Converts the Scintilla cursor enum into an NSCursor and stores it in the associated NSView,
 * which then will take care to set up a new mouse tracking rectangle.
 */
void Window::SetCursor(Cursor curs)
{
  if (wid)
  {
    id idWin = static_cast<id>(wid);
    if ([idWin isKindOfClass: [SCIContentView class]])
    {
      SCIContentView* container = idWin;
      [container setCursor: curs];
    }
  }
}

//--------------------------------------------------------------------------------------------------

PRectangle Window::GetMonitorRect(Point)
{
  if (wid)
  {
    id idWin = static_cast<id>(wid);
    if ([idWin isKindOfClass: [NSView class]])
    {
      NSView* view = idWin;
      idWin = [view window];
    }
    if ([idWin isKindOfClass: [NSWindow class]])
    {
      PRectangle rcPosition = GetPosition();

      NSWindow* win = idWin;
      NSScreen* screen = [win screen];
      NSRect rect = [screen visibleFrame];
      CGFloat screenHeight = rect.origin.y + rect.size.height;
      // Invert screen positions to match Scintilla
      PRectangle rcWork(
          static_cast<XYPOSITION>(NSMinX(rect)), static_cast<XYPOSITION>(screenHeight - NSMaxY(rect)),
          static_cast<XYPOSITION>(NSMaxX(rect)), static_cast<XYPOSITION>(screenHeight - NSMinY(rect)));
      PRectangle rcMonitor(rcWork.left - rcPosition.left,
                           rcWork.top - rcPosition.top,
                           rcWork.right - rcPosition.left,
                           rcWork.bottom - rcPosition.top);
      return rcMonitor;
    }
  }
  return PRectangle();
}

//----------------- ImageFromXPM -------------------------------------------------------------------

// Convert an XPM image into an NSImage for use with Cocoa

static NSImage* ImageFromXPM(XPM* pxpm)
{
  NSImage* img = nil;
  if (pxpm)
  {
    const int width = pxpm->GetWidth();
    const int height = pxpm->GetHeight();
    PRectangle rcxpm(0, 0, width, height);
    std::unique_ptr<Surface> surfaceXPM(Surface::Allocate(SC_TECHNOLOGY_DEFAULT));
    surfaceXPM->InitPixMap(width, height, NULL, NULL);
    SurfaceImpl* surfaceIXPM = static_cast<SurfaceImpl*>(surfaceXPM.get());
    CGContextClearRect(surfaceIXPM->GetContext(), CGRectMake(0, 0, width, height));
    pxpm->Draw(surfaceXPM.get(), rcxpm);
    CGImageRef imageRef = surfaceIXPM->GetImage();
    img = [[NSImage alloc] initWithCGImage:imageRef size: NSZeroSize];
    CGImageRelease(imageRef);
  }
  return img;
}

//----------------- ListBox and related classes ----------------------------------------------------

//----------------- IListBox -----------------------------------------------------------------------

namespace {

// Unnamed namespace hides local IListBox interface.
// IListBox is used to cross languages to send events from Objective C++
// AutoCompletionDelegate and AutoCompletionDataSource to C++ ListBoxImpl.

class IListBox {
public:
  virtual int Rows() = 0;
  virtual NSImage* ImageForRow(NSInteger row) = 0;
  virtual NSString* TextForRow(NSInteger row) = 0;
  virtual void DoubleClick() = 0;
  virtual void SelectionChange() = 0;
};

}

//----------------- AutoCompletionDelegate ---------------------------------------------------------

// AutoCompletionDelegate is an Objective C++ class so it can implement
// NSTableViewDelegate and receive tableViewSelectionDidChange events.

@interface AutoCompletionDelegate : NSObject <NSTableViewDelegate> {
	IListBox *box;
}

@property IListBox *box;

@end

@implementation AutoCompletionDelegate

@synthesize box;

- (void) tableViewSelectionDidChange: (NSNotification *) notification {
#pragma unused(notification)
	if (box) {
		box->SelectionChange();
	}
}

@end

//----------------- AutoCompletionDataSource -------------------------------------------------------

// AutoCompletionDataSource provides data to display in the list box.
// It is also the target of the NSTableView so it receives double clicks.

@interface AutoCompletionDataSource : NSObject <NSTableViewDataSource> {
	IListBox *box;
}

@property IListBox* box;

@end

@implementation AutoCompletionDataSource

@synthesize box;

- (void) doubleClick: (id) sender
{
#pragma unused(sender)
	if (box)
	{
		box->DoubleClick();
	}
}

- (id)tableView: (NSTableView*)aTableView objectValueForTableColumn: (NSTableColumn*)aTableColumn row: (NSInteger)rowIndex
{
#pragma unused(aTableView)
	if (!box)
		return nil;
	if ([(NSString*)[aTableColumn identifier] isEqualToString: @"icon"])
	{
		return box->ImageForRow(rowIndex);
	}
	else {
		return box->TextForRow(rowIndex);
	}
}

- (void)tableView: (NSTableView*)aTableView setObjectValue: anObject forTableColumn: (NSTableColumn*)aTableColumn row: (NSInteger)rowIndex
{
#pragma unused(aTableView)
#pragma unused(anObject)
#pragma unused(aTableColumn)
#pragma unused(rowIndex)
}

- (NSInteger)numberOfRowsInTableView: (NSTableView*)aTableView
{
#pragma unused(aTableView)
	if (!box)
		return 0;
	return box->Rows();
}

@end

//----------------- ListBoxImpl --------------------------------------------------------------------

namespace {	// unnamed namespace hides ListBoxImpl and associated classes

struct RowData
{
  int type;
  std::string text;
  RowData(int type_, const char* text_) :
    type(type_), text(text_)
  {
  }
};

class LinesData
{
  std::vector<RowData> lines;
public:
  LinesData()
  {
  }
  ~LinesData()
  {
  }
  int Length() const
  {
    return static_cast<int>(lines.size());
  }
  void Clear()
  {
    lines.clear();
  }
  void Add(int /* index */, int type, char* str)
  {
    lines.push_back(RowData(type, str));
  }
  int GetType(size_t index) const
  {
    if (index < lines.size())
    {
      return lines[index].type;
    }
    else
    {
      return 0;
    }
  }
  const char* GetString(size_t index) const
  {
    if (index < lines.size())
    {
      return lines[index].text.c_str();
    }
    else
    {
      return 0;
    }
  }
};

class ListBoxImpl : public ListBox, IListBox
{
private:
  NSMutableDictionary *images;
  int lineHeight;
  bool unicodeMode;
  int desiredVisibleRows;
  XYPOSITION maxItemWidth;
  unsigned int aveCharWidth;
  XYPOSITION maxIconWidth;
  Font font;
  int maxWidth;

  NSTableView* table;
  NSScrollView* scroller;
  NSTableColumn* colIcon;
  NSTableColumn* colText;
  AutoCompletionDataSource* ds;
  AutoCompletionDelegate *acd;

  LinesData ld;
  IListBoxDelegate *delegate;

public:
  ListBoxImpl() :
    images(nil),
    lineHeight(10),
    unicodeMode(false),
    desiredVisibleRows(5),
    maxItemWidth(0),
    aveCharWidth(8),
    maxIconWidth(0),
    maxWidth(2000),
    table(nil),
    scroller(nil),
    colIcon(nil),
    colText(nil),
    ds(nil),
    acd(nil),
    delegate(nullptr)
  {
    images = [[NSMutableDictionary alloc] init];
  }
  ~ListBoxImpl() override {
    [images release];
  }

  // ListBox methods
  void SetFont(Font& font) override;
  void Create(Window& parent, int ctrlID, Scintilla::Point pt, int lineHeight_, bool unicodeMode_, int technology_) override;
  void SetAverageCharWidth(int width) override;
  void SetVisibleRows(int rows) override;
  int GetVisibleRows() const override;
  PRectangle GetDesiredRect() override;
  int CaretFromEdge() override;
  void Clear() override;
  void Append(char* s, int type = -1) override;
  int Length() override;
  void Select(int n) override;
  int GetSelection() override;
  int Find(const char* prefix) override;
  void GetValue(int n, char* value, int len) override;
  void RegisterImage(int type, const char* xpm_data) override;
  void RegisterRGBAImage(int type, int width, int height, const unsigned char *pixelsImage) override;
  void ClearRegisteredImages() override;
	void SetDelegate(IListBoxDelegate *lbDelegate) override {
		delegate = lbDelegate;
  }
  void SetList(const char* list, char separator, char typesep) override;

  // To clean up when closed
  void ReleaseViews();

  // For access from AutoCompletionDataSource implement IListBox
  int Rows() override;
  NSImage* ImageForRow(NSInteger row) override;
  NSString* TextForRow(NSInteger row) override;
  void DoubleClick() override;
  void SelectionChange() override;
};

void ListBoxImpl::Create(Window& /*parent*/, int /*ctrlID*/, Scintilla::Point pt,
    int lineHeight_, bool unicodeMode_, int)
{
  lineHeight = lineHeight_;
  unicodeMode = unicodeMode_;
  maxWidth = 2000;

  NSRect lbRect = NSMakeRect(pt.x,pt.y, 120, lineHeight * desiredVisibleRows);
  NSWindow* winLB = [[NSWindow alloc] initWithContentRect: lbRect
    styleMask: NSBorderlessWindowMask
    backing: NSBackingStoreBuffered
    defer: NO];
  [winLB setLevel:NSFloatingWindowLevel];
  [winLB setHasShadow:YES];
  scroller = [NSScrollView alloc];
  NSRect scRect = NSMakeRect(0, 0, lbRect.size.width, lbRect.size.height);
  [scroller initWithFrame: scRect];
  [scroller setHasVerticalScroller:YES];
  table = [[NSTableView alloc] initWithFrame: scRect];
  [table setHeaderView:nil];
  [scroller setDocumentView: table];
  colIcon = [[NSTableColumn alloc] initWithIdentifier:@"icon"];
  [colIcon setWidth: 20];
  [colIcon setEditable:NO];
  [colIcon setHidden:YES];
  NSImageCell* imCell = [[[NSImageCell alloc] init] autorelease];
  [colIcon setDataCell:imCell];
  [table addTableColumn:colIcon];
  colText = [[NSTableColumn alloc] initWithIdentifier:@"name"];
  [colText setResizingMask:NSTableColumnAutoresizingMask];
  [colText setEditable:NO];
  [table addTableColumn:colText];
  ds = [[AutoCompletionDataSource alloc] init];
  [ds setBox:this];
  [table setDataSource: ds];	// Weak reference
  acd = [[AutoCompletionDelegate alloc] init];
  [acd setBox: this];
  [table setDelegate: acd];
  [scroller setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  [[winLB contentView] addSubview: scroller];

  [table setTarget:ds];
  [table setDoubleAction:@selector(doubleClick:)];
  table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;
  wid = winLB;
}

void ListBoxImpl::SetFont(Font& font_)
{
  // NSCell setFont takes an NSFont* rather than a CTFontRef but they
  // are the same thing toll-free bridged.
	QuartzTextStyle *style = TextStyleFromFont(font_);
  font.Release();
  font.SetID(new QuartzTextStyle(*style));
  NSFont *pfont = (NSFont *)style->getFontRef();
  [[colText dataCell] setFont: pfont];
  CGFloat itemHeight = ceil([pfont boundingRectForFont].size.height);
  [table setRowHeight:itemHeight];
}

void ListBoxImpl::SetAverageCharWidth(int width)
{
  aveCharWidth = width;
}

void ListBoxImpl::SetVisibleRows(int rows)
{
  desiredVisibleRows = rows;
}

int ListBoxImpl::GetVisibleRows() const
{
  return desiredVisibleRows;
}

PRectangle ListBoxImpl::GetDesiredRect()
{
  PRectangle rcDesired;
  rcDesired = GetPosition();

  // There appears to be an extra pixel above and below the row contents
  CGFloat itemHeight = [table rowHeight] + 2;

  int rows = Length();
  if ((rows == 0) || (rows > desiredVisibleRows))
    rows = desiredVisibleRows;

  rcDesired.bottom = rcDesired.top + static_cast<XYPOSITION>(itemHeight * rows);
  rcDesired.right = rcDesired.left + maxItemWidth + aveCharWidth;
  rcDesired.right += 4; // Ensures no truncation of text

  if (Length() > rows)
  {
    [scroller setHasVerticalScroller:YES];
    rcDesired.right += [NSScroller scrollerWidthForControlSize:NSRegularControlSize
						 scrollerStyle:NSScrollerStyleLegacy];
  }
  else
  {
    [scroller setHasVerticalScroller:NO];
  }
  rcDesired.right += maxIconWidth;
  rcDesired.right += 6; // For icon space

  return rcDesired;
}

int ListBoxImpl::CaretFromEdge()
{
  if ([colIcon isHidden])
    return 3;
  else
    return 6 + static_cast<int>([colIcon width]);
}

void ListBoxImpl::ReleaseViews()
{
  [table setDataSource:nil];
  [table release];
  table = nil;
  [scroller release];
  scroller = nil;
  [colIcon release];
  colIcon = nil;
  [colText release ];
  colText = nil;
  [acd release];
  acd = nil;
  [ds release];
  ds = nil;
}

void ListBoxImpl::Clear()
{
  maxItemWidth = 0;
  maxIconWidth = 0;
  ld.Clear();
}

void ListBoxImpl::Append(char* s, int type)
{
  int count = Length();
  ld.Add(count, type, s);

  Scintilla::SurfaceImpl surface;
  XYPOSITION width = surface.WidthText(font, s, static_cast<int>(strlen(s)));
  if (width > maxItemWidth)
  {
    maxItemWidth = width;
    [colText setWidth: maxItemWidth];
  }
  NSImage *img = images[@(type)];
  if (img)
  {
    XYPOSITION widthIcon = static_cast<XYPOSITION>(img.size.width);
    if (widthIcon > maxIconWidth)
    {
      [colIcon setHidden: NO];
      maxIconWidth = widthIcon;
      [colIcon setWidth: maxIconWidth];
    }
  }
}

void ListBoxImpl::SetList(const char* list, char separator, char typesep)
{
  Clear();
  size_t count = strlen(list) + 1;
  std::vector<char> words(list, list+count);
  char *startword = words.data();
  char *numword = nullptr;
  int i = 0;
  for (; words[i]; i++)
  {
    if (words[i] == separator)
    {
      words[i] = '\0';
      if (numword)
        *numword = '\0';
      Append(startword, numword?atoi(numword + 1):-1);
      startword = words.data() + i + 1;
      numword = nullptr;
    }
    else if (words[i] == typesep)
    {
      numword = words.data() + i;
    }
  }
  if (startword)
  {
    if (numword)
      *numword = '\0';
    Append(startword, numword?atoi(numword + 1):-1);
  }
  [table reloadData];
}

int ListBoxImpl::Length()
{
  return ld.Length();
}

void ListBoxImpl::Select(int n)
{
  [table selectRowIndexes:[NSIndexSet indexSetWithIndex:n] byExtendingSelection:NO];
  [table scrollRowToVisible:n];
}

int ListBoxImpl::GetSelection()
{
  return static_cast<int>([table selectedRow]);
}

int ListBoxImpl::Find(const char* prefix)
{
  int count = Length();
  for (int i = 0; i < count; i++)
  {
    const char* s = ld.GetString(i);
    if (s && (s[0] != '\0') && (0 == strncmp(prefix, s, strlen(prefix))))
    {
      return i;
    }
  }
  return - 1;
}

void ListBoxImpl::GetValue(int n, char* value, int len)
{
  const char* textString = ld.GetString(n);
  if (textString == NULL)
  {
    value[0] = '\0';
    return;
  }
  strlcpy(value, textString, len);
}

void ListBoxImpl::RegisterImage(int type, const char* xpm_data)
{
  XPM xpm(xpm_data);
  NSImage* img = ImageFromXPM(&xpm);
  [images setObject:img forKey:@(type)];
  [img release];
}

void ListBoxImpl::RegisterRGBAImage(int type, int width, int height, const unsigned char *pixelsImage)
{
  CGImageRef imageRef = ImageCreateFromRGBA(width, height, pixelsImage, false);
  NSImage *img = [[NSImage alloc] initWithCGImage:imageRef size: NSZeroSize];
  CGImageRelease(imageRef);
  [images setObject:img forKey:@(type)];
  [img release];
}

void ListBoxImpl::ClearRegisteredImages()
{
  [images removeAllObjects];
}

int ListBoxImpl::Rows()
{
  return ld.Length();
}

NSImage* ListBoxImpl::ImageForRow(NSInteger row)
{
  return images[@(ld.GetType(row))];
}

NSString* ListBoxImpl::TextForRow(NSInteger row)
{
  const char* textString = ld.GetString(row);
  NSString* sTitle;
  if (unicodeMode)
    sTitle = [NSString stringWithUTF8String:textString];
  else
    sTitle = [NSString stringWithCString:textString encoding:NSWindowsCP1252StringEncoding];
  return sTitle;
}

void ListBoxImpl::DoubleClick() {
	if (delegate) {
		ListBoxEvent event(ListBoxEvent::EventType::doubleClick);
		delegate->ListNotify(&event);
	}
}

void ListBoxImpl::SelectionChange() {
	if (delegate) {
		ListBoxEvent event(ListBoxEvent::EventType::selectionChange);
		delegate->ListNotify(&event);
  }
}

} // unnamed namespace

//----------------- ListBox ------------------------------------------------------------------------

// ListBox is implemented by the ListBoxImpl class.

ListBox::ListBox()
{
}

ListBox::~ListBox()
{
}

ListBox* ListBox::Allocate()
{
	ListBoxImpl* lb = new ListBoxImpl();
	return lb;
}

//--------------------------------------------------------------------------------------------------

void Window::Destroy()
{
  ListBoxImpl *listbox = dynamic_cast<ListBoxImpl *>(this);
  if (listbox)
  {
    listbox->ReleaseViews();
  }
  if (wid)
  {
    id idWin = static_cast<id>(wid);
    if ([idWin isKindOfClass: [NSWindow class]])
    {
      [idWin close];
    }
  }
  wid = 0;
}


//----------------- ScintillaContextMenu -----------------------------------------------------------

@implementation ScintillaContextMenu : NSMenu

// This NSMenu subclass serves also as target for menu commands and forwards them as
// notification messages to the front end.

- (void) handleCommand: (NSMenuItem*) sender
{
  owner->HandleCommand([sender tag]);
}

//--------------------------------------------------------------------------------------------------

- (void) setOwner: (Scintilla::ScintillaCocoa*) newOwner
{
  owner = newOwner;
}

@end

//----------------- Menu ---------------------------------------------------------------------------

Menu::Menu()
  : mid(0)
{
}

//--------------------------------------------------------------------------------------------------

void Menu::CreatePopUp()
{
  Destroy();
  mid = [[ScintillaContextMenu alloc] initWithTitle: @""];
}

//--------------------------------------------------------------------------------------------------

void Menu::Destroy()
{
  ScintillaContextMenu* menu = static_cast<ScintillaContextMenu*>(mid);
  [menu release];
  mid = NULL;
}

//--------------------------------------------------------------------------------------------------

void Menu::Show(Point, Window &)
{
  // Cocoa menus are handled a bit differently. We only create the menu. The framework
  // takes care to show it properly.
}

//----------------- Platform -----------------------------------------------------------------------

ColourDesired Platform::Chrome()
{
  return ColourDesired(0xE0, 0xE0, 0xE0);
}

//--------------------------------------------------------------------------------------------------

ColourDesired Platform::ChromeHighlight()
{
  return ColourDesired(0xFF, 0xFF, 0xFF);
}

//--------------------------------------------------------------------------------------------------

/**
 * Returns the currently set system font for the user.
 */
const char *Platform::DefaultFont()
{
  NSString* name = [[NSUserDefaults standardUserDefaults] stringForKey: @"NSFixedPitchFont"];
  return [name UTF8String];
}

//--------------------------------------------------------------------------------------------------

/**
 * Returns the currently set system font size for the user.
 */
int Platform::DefaultFontSize()
{
  return static_cast<int>([[NSUserDefaults standardUserDefaults]
			   integerForKey: @"NSFixedPitchFontSize"]);
}

//--------------------------------------------------------------------------------------------------

/**
 * Returns the time span in which two consecutive mouse clicks must occur to be considered as
 * double click.
 *
 * @return time span in milliseconds
 */
unsigned int Platform::DoubleClickTime()
{
  float threshold = [[NSUserDefaults standardUserDefaults] floatForKey:
                     @"com.apple.mouse.doubleClickThreshold"];
  if (threshold == 0)
    threshold = 0.5;
  return static_cast<unsigned int>(threshold * 1000.0);
}

//--------------------------------------------------------------------------------------------------

//#define TRACE
#ifdef TRACE

void Platform::DebugDisplay(const char *s)
{
  fprintf( stderr, "%s", s );
}

//--------------------------------------------------------------------------------------------------

void Platform::DebugPrintf(const char *format, ...)
{
  const int BUF_SIZE = 2000;
  char buffer[BUF_SIZE];

  va_list pArguments;
  va_start(pArguments, format);
  vsnprintf(buffer, BUF_SIZE, format, pArguments);
  va_end(pArguments);
  Platform::DebugDisplay(buffer);
}

#else

void Platform::DebugDisplay(const char *) {}

void Platform::DebugPrintf(const char *, ...) {}

#endif

//--------------------------------------------------------------------------------------------------

static bool assertionPopUps = true;

bool Platform::ShowAssertionPopUps(bool assertionPopUps_)
{
  bool ret = assertionPopUps;
  assertionPopUps = assertionPopUps_;
  return ret;
}

//--------------------------------------------------------------------------------------------------

void Platform::Assert(const char *c, const char *file, int line)
{
  char buffer[2000];
  snprintf(buffer, sizeof(buffer), "Assertion [%s] failed at %s %d\r\n", c, file, line);
  Platform::DebugDisplay(buffer);
#ifdef DEBUG
  // Jump into debugger in assert on Mac (CL269835)
  ::Debugger();
#endif
}

//----------------- DynamicLibrary -----------------------------------------------------------------

/**
 * Implements the platform specific part of library loading.
 *
 * @param modulePath The path to the module to load.
 * @return A library instance or nullptr if the module could not be found or another problem occurred.
 */
DynamicLibrary* DynamicLibrary::Load(const char* /* modulePath */)
{
  // Not implemented.
  return nullptr;
}

//--------------------------------------------------------------------------------------------------

