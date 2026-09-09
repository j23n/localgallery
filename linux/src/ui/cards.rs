//! Photo cards and rails for Collections (and chip-adjacent chrome).

use gtk::prelude::*;
use gtk::{Align, Orientation};

/// Section title that drills in. Chevron says there is a list behind it.
pub fn section_header(title: &str, subtitle: &str, activate: impl Fn() + 'static) -> gtk::Widget {
    let title_l = gtk::Label::new(Some(title));
    title_l.add_css_class("title-3");
    title_l.set_xalign(0.0);
    title_l.set_hexpand(true);
    let sub = gtk::Label::new(Some(subtitle));
    sub.add_css_class("dim-label");
    sub.set_xalign(1.0);
    let chevron = gtk::Image::from_icon_name("go-next-symbolic");
    chevron.add_css_class("dim-label");
    let row = gtk::Box::new(Orientation::Horizontal, 8);
    row.set_margin_start(16);
    row.set_margin_end(12);
    row.set_margin_top(18);
    row.set_margin_bottom(8);
    row.append(&title_l);
    row.append(&sub);
    row.append(&chevron);
    let btn = gtk::Button::new();
    btn.set_child(Some(&row));
    btn.add_css_class("flat");
    btn.connect_clicked(move |_| activate());
    btn.upcast()
}

/// Horizontal scroller that sizes to its cards.
pub fn rail(children: impl IntoIterator<Item = gtk::Widget>) -> gtk::Widget {
    let box_ = gtk::Box::new(Orientation::Horizontal, 10);
    box_.set_margin_start(16);
    box_.set_margin_end(16);
    box_.set_margin_bottom(4);
    for child in children {
        box_.append(&child);
    }
    let sw = gtk::ScrolledWindow::new();
    sw.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Never);
    sw.set_propagate_natural_height(true);
    sw.set_child(Some(&box_));
    sw.add_css_class("undershoot-end");
    sw.upcast()
}

/// Two-row column-major rail (iOS People). `pairs` is already chunked.
pub fn paired_rail(columns: impl IntoIterator<Item = Vec<gtk::Widget>>) -> gtk::Widget {
    let box_ = gtk::Box::new(Orientation::Horizontal, 10);
    box_.set_margin_start(16);
    box_.set_margin_end(16);
    box_.set_margin_bottom(4);
    for col in columns {
        let stack = gtk::Box::new(Orientation::Vertical, 10);
        for child in col {
            stack.append(&child);
        }
        box_.append(&stack);
    }
    let sw = gtk::ScrolledWindow::new();
    sw.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Never);
    sw.set_propagate_natural_height(true);
    sw.set_child(Some(&box_));
    sw.upcast()
}

/// Square cover with a caption on the photo.
pub fn cover_card(
    picture: gtk::Picture,
    title: &str,
    subtitle: &str,
    side: i32,
    activate: impl Fn() + 'static,
) -> gtk::Widget {
    picture.set_content_fit(gtk::ContentFit::Cover);
    picture.set_can_shrink(true);
    picture.set_size_request(side, side);
    picture.set_hexpand(true);
    picture.set_vexpand(true);

    let name = gtk::Label::new(Some(title));
    name.add_css_class("heading");
    name.add_css_class("osd");
    name.set_xalign(0.0);
    name.set_ellipsize(gtk::pango::EllipsizeMode::End);
    let count = gtk::Label::new(Some(subtitle));
    count.add_css_class("caption");
    count.add_css_class("osd");
    count.set_xalign(0.0);
    let labels = gtk::Box::new(Orientation::Vertical, 0);
    labels.set_valign(Align::End);
    labels.set_halign(Align::Fill);
    labels.set_margin_start(8);
    labels.set_margin_end(8);
    labels.set_margin_bottom(6);
    labels.append(&name);
    labels.append(&count);

    let overlay = gtk::Overlay::new();
    overlay.set_size_request(side, side);
    overlay.set_child(Some(&picture));
    overlay.add_overlay(&labels);

    let btn = gtk::Button::new();
    btn.set_child(Some(&overlay));
    btn.add_css_class("flat");
    btn.add_css_class("card");
    btn.connect_clicked(move |_| activate());
    btn.upcast()
}

/// Review tile on the People rail — same size as a face card.
pub fn review_card(count: usize, side: i32, activate: impl Fn() + 'static) -> gtk::Widget {
    let icon = gtk::Image::from_icon_name("avatar-default-symbolic");
    icon.set_pixel_size(side / 3);
    icon.add_css_class("dim-label");
    let title = gtk::Label::new(Some("Review"));
    title.add_css_class("heading");
    let sub = gtk::Label::new(Some(&format!("{} unnamed", count)));
    sub.add_css_class("dim-label");
    let col = gtk::Box::new(Orientation::Vertical, 4);
    col.set_halign(Align::Center);
    col.set_valign(Align::Center);
    col.append(&icon);
    col.append(&title);
    col.append(&sub);
    let frame = gtk::Box::new(Orientation::Vertical, 0);
    frame.set_size_request(side, side);
    frame.add_css_class("card");
    frame.set_halign(Align::Fill);
    frame.set_valign(Align::Fill);
    frame.set_hexpand(true);
    frame.set_vexpand(true);
    let wrap = gtk::Box::new(Orientation::Vertical, 0);
    wrap.set_hexpand(true);
    wrap.set_vexpand(true);
    wrap.set_halign(Align::Center);
    wrap.set_valign(Align::Center);
    wrap.append(&col);
    frame.append(&wrap);
    let btn = gtk::Button::new();
    btn.set_child(Some(&frame));
    btn.add_css_class("flat");
    btn.connect_clicked(move |_| activate());
    btn.upcast()
}

/// iOS-style event row: cover + name + count + dates.
pub fn event_row(
    picture: gtk::Picture,
    title: &str,
    subtitle: &str,
    dates: Option<&str>,
    activate: impl Fn() + 'static,
) -> gtk::Widget {
    picture.set_content_fit(gtk::ContentFit::Cover);
    picture.set_size_request(68, 68);
    picture.add_css_class("card");
    let name = gtk::Label::new(Some(title));
    name.add_css_class("heading");
    name.set_xalign(0.0);
    name.set_ellipsize(gtk::pango::EllipsizeMode::End);
    let count = gtk::Label::new(Some(subtitle));
    count.add_css_class("dim-label");
    count.set_xalign(0.0);
    let labels = gtk::Box::new(Orientation::Vertical, 2);
    labels.set_hexpand(true);
    labels.append(&name);
    labels.append(&count);
    if let Some(dates) = dates {
        let d = gtk::Label::new(Some(dates));
        d.add_css_class("caption");
        d.add_css_class("dim-label");
        d.set_xalign(0.0);
        labels.append(&d);
    }
    let chevron = gtk::Image::from_icon_name("go-next-symbolic");
    chevron.add_css_class("dim-label");
    let row = gtk::Box::new(Orientation::Horizontal, 14);
    row.set_margin_start(16);
    row.set_margin_end(16);
    row.set_margin_top(8);
    row.set_margin_bottom(8);
    row.append(&picture);
    row.append(&labels);
    row.append(&chevron);
    let btn = gtk::Button::new();
    btn.set_child(Some(&row));
    btn.add_css_class("flat");
    btn.connect_clicked(move |_| activate());
    btn.upcast()
}

/// Filter chip. `active` is the current required-tag state.
pub fn tag_chip(label: &str, active: bool, toggle: impl Fn() + 'static) -> gtk::Widget {
    let btn = gtk::ToggleButton::with_label(label);
    btn.set_active(active);
    btn.add_css_class("pill");
    btn.connect_clicked(move |_| toggle());
    btn.upcast()
}
