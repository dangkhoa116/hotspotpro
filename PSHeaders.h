// Minimal declarations for the bits of Preferences.framework the Settings hook
// needs. Declared here rather than pulled from a headers package so the build
// keeps working with a stock Theos install and nothing to install alongside it.

#import <UIKit/UIKit.h>

typedef enum {
    PSGroupCell = 0,
    PSLinkCell,
    PSLinkListCell,
    PSListItemCell,
    PSTitleValueCell,
    PSSliderCell,
    PSSwitchCell,
    PSStaticTextCell,
    PSEditTextCell,
    PSSegmentCell,
    PSGiantIconCell,
    PSGiantCell,
    PSSecureEditTextCell,
    PSButtonCell,
    PSEditTextViewCell,
} PSCellType;

@interface PSSpecifier : NSObject
@property (nonatomic, retain) NSString *name;
@property (nonatomic, retain) NSString *identifier;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(PSCellType)cell
                                    edit:(Class)edit;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
// A PSButtonCell dispatches through this, not through an "action" string
// property — setting the string silently does nothing when tapped.
- (void)setButtonAction:(SEL)action;
- (void)setTarget:(id)target;
// Backs a PSLinkListCell: the choices and their labels.
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

/// The stock checklist pane a PSLinkListCell pushes.
@interface PSListItemsController : UIViewController
@end

/// Base class for preference cells. A specifier can name a subclass through its
/// "cellClass" property, which is how a custom control gets into a pane.
@interface PSTableCell : UITableViewCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier;
@property (nonatomic, retain) PSSpecifier *specifier;
@end

@interface PSListController : UIViewController <UITableViewDelegate, UITableViewDataSource>
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)insertContiguousSpecifiers:(NSArray *)specifiers
                           atIndex:(NSUInteger)index
                          animated:(BOOL)animated;
- (void)removeContiguousSpecifiers:(NSArray *)specifiers animated:(BOOL)animated;
- (void)removeSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (UITableView *)table;
- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (NSIndexPath *)indexPathForSpecifier:(PSSpecifier *)specifier;
// The specifier that pushed this controller, set by the framework on the way in.
- (void)setSpecifier:(PSSpecifier *)specifier;
- (PSSpecifier *)specifier;
@end
