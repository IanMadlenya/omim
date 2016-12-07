#import "MWMiPadPlacePageLayoutImpl.h"
#import "MWMPlacePageLayout.h"

namespace
{
CGFloat const kPlacePageWidth = 360;
CGFloat const kLeftOffset = 12;
CGFloat const kTopOffset = 36;
CGFloat const kBottomOffset = 60;
}  // namespace

@interface MWMPPView (ActionBarLayout)

@end

@implementation MWMPPView (ActionBarLayout)

- (void)layoutSubviews
{
  [super layoutSubviews];
  if (!IPAD)
    return;

  for (UIView * sv in self.subviews)
  {
    if (![sv isKindOfClass:[MWMPlacePageActionBar class]])
      continue;
    sv.maxY = self.height;
    break;
  }
}

@end

@interface MWMiPadPlacePageLayoutImpl ()

@property(nonatomic) CGFloat topBound;
@property(nonatomic) CGFloat leftBound;

@end

@implementation MWMiPadPlacePageLayoutImpl

@synthesize ownerView = _ownerView;
@synthesize placePageView = _placePageView;
@synthesize delegate = _delegate;
@synthesize actionBar = _actionBar;

- (instancetype)initOwnerView:(UIView *)ownerView
                placePageView:(MWMPPView *)placePageView
                     delegate:(id<MWMPlacePageLayoutDelegate>)delegate
{
  self = [super init];
  if (self)
  {
    _ownerView = ownerView;
    self.placePageView = placePageView;
    _delegate = delegate;
    [self addShadow];
  }
  return self;
}

- (void)addShadow
{
  CALayer * layer = self.placePageView.layer;
  layer.masksToBounds = NO;
  layer.shadowColor = UIColor.blackColor.CGColor;
  layer.shadowRadius = 4.;
  layer.shadowOpacity = 0.24f;
  layer.shadowOffset = {0, -2};
  layer.shouldRasterize = YES;
  layer.rasterizationScale = [[UIScreen mainScreen] scale];
}

- (void)onShow
{
  auto ppView = self.placePageView;
  auto actionBar = self.actionBar;
  ppView.tableView.scrollEnabled = NO;
  actionBar.alpha = 0;
  ppView.alpha = 0;
  ppView.origin = {- kPlacePageWidth, self.topBound};
  [self.ownerView addSubview:ppView];

  place_page_layout::animate(^{
    ppView.alpha = 1;
    actionBar.alpha = 1;
    ppView.minX = self.leftBound;
  });
}

- (void)onClose
{
  auto ppView = self.placePageView;
  place_page_layout::animate(
      ^{
        ppView.maxX = 0;
        ppView.alpha = 0;
      },
      ^{
        self.placePageView = nil;
        self.actionBar = nil;
        [self.delegate shouldDestroyLayout];
      });
}

- (void)onScreenResize:(CGSize const &)size
{
  [self layoutPlacePage:self.placePageView.tableView.contentSize.height onScreen:size.height];
}

- (void)onUpdatePlacePageWithHeight:(CGFloat)height
{
  [self layoutPlacePage:height onScreen:self.ownerView.height];
}

- (void)setInitialTopBound:(CGFloat)topBound leftBound:(CGFloat)leftBound
{
  self.topBound = topBound;
  self.leftBound = leftBound;
}

- (void)updateLayoutWithTopBound:(CGFloat)topBound
{
  self.topBound = topBound;
  [self layoutPlacePage:self.placePageView.tableView.contentSize.height onScreen:self.ownerView.height];
}

- (void)updateLayoutWithLeftBound:(CGFloat)leftBound
{
  self.leftBound = leftBound;
  place_page_layout::animate(^{
    self.placePageView.minX = self.leftBound;
  });
}

- (void)layoutPlacePage:(CGFloat)placePageHeight onScreen:(CGFloat)screenHeight
{
  BOOL const isPlacePageWithinScreen = [self isPlacePage:placePageHeight withinScreen:screenHeight];
  auto ppView = self.placePageView;

  place_page_layout::animate(^{
    ppView.minY = self.topBound;
  });

  ppView.height = [self actualPlacePageViewHeightWithPlacePageHeight:placePageHeight
                                                        screenHeight:screenHeight];

  if (!ppView.tableView.scrollEnabled && !isPlacePageWithinScreen)
    ppView.tableView.scrollEnabled = YES;
}

- (CGFloat)actualPlacePageViewHeightWithPlacePageHeight:(CGFloat)placePageHeight
                                           screenHeight:(CGFloat)screenHeight
{
  auto ppView = self.placePageView;
  if ([self isPlacePage:placePageHeight withinScreen:screenHeight])
    return placePageHeight + ppView.top.height;

  return screenHeight - kBottomOffset - self.topBound + (ppView.tableView.scrollEnabled ?
                                                         self.actionBar.height : 0);
}

- (BOOL)isPlacePage:(CGFloat)placePageHeight withinScreen:(CGFloat)screenHeight
{
  auto const placePageFullHeight = placePageHeight;
  auto const availableSpace = screenHeight - self.topBound - kBottomOffset;
  return availableSpace > placePageFullHeight;
}

#pragma mark - Pan

- (void)didPan:(UIPanGestureRecognizer *)pan
{
  MWMPPView * view = self.placePageView;
  auto superview = view.superview;

  CGFloat const leftOffset = self.leftBound;
  view.minX += [pan translationInView:superview].x;
  view.minX = MIN(view.minX, leftOffset);
  [pan setTranslation:CGPointZero inView:superview];

  CGFloat const alpha = MAX(0.0, view.maxX) / (view.width + leftOffset);
  view.alpha = alpha;
  UIGestureRecognizerState const state = pan.state;
  if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled)
  {
    CGFloat constexpr designAlpha = 0.8;
    if (alpha < designAlpha)
    {
      [self.delegate shouldClose];
    }
    else
    {
      place_page_layout::animate(^{
        view.minX = leftOffset;
        view.alpha = 1;
      });
    }
  }
}

#pragma mark - Top and left bound

- (CGFloat)topBound { return _topBound + kTopOffset; }
- (CGFloat)leftBound { return _leftBound + kLeftOffset; }
#pragma mark - Properties

- (void)setPlacePageView:(MWMPPView *)placePageView
{
  if (placePageView)
  {
    placePageView.width = kPlacePageWidth;
    placePageView.anchorImage.hidden = YES;
    auto pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(didPan:)];
    [placePageView addGestureRecognizer:pan];
  }
  else
  {
    [_placePageView removeFromSuperview];
  }
  _placePageView = placePageView;
}

- (void)setActionBar:(MWMPlacePageActionBar *)actionBar
{
  if (actionBar)
  {
    auto superview = self.placePageView;
    actionBar.origin = {0., superview.height - actionBar.height};
    [superview addSubview:actionBar];
  }
  else
  {
    [_actionBar removeFromSuperview];
  }
  _actionBar = actionBar;
}

@end
