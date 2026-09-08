//! GTK / libadwaita shell. One window: laptop chrome or the Comet collapse.

use std::env;

use adw::prelude::*;

const APP_ID: &str = "com.j23n.LocalGallery";

fn main() {
    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_activate(move |app| {
        let comet = env::args().any(|a| a == "--comet");
        localgallery::ui::Window::present(app, comet);
    });
    let argv: Vec<String> = env::args().filter(|a| a != "--comet").collect();
    app.run_with_args(&argv);
}
