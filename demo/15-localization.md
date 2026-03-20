# Localization (i18n)

Tina4 Ruby provides internationalization with JSON and YAML translation files, dot-notation key lookup, string interpolation, and locale fallback to English. Translations are loaded automatically from `locales/`, `translations/`, `i18n/`, or `src/locales/` directories.

## Translation Files

Create JSON files named by locale code:

**locales/en.json:**
```json
{
  "greeting": "Hello, %{name}!",
  "goodbye": "Goodbye!",
  "nav": {
    "home": "Home",
    "about": "About",
    "contact": "Contact"
  },
  "items_count": "You have %{count} items"
}
```

**locales/fr.json:**
```json
{
  "greeting": "Bonjour, %{name} !",
  "goodbye": "Au revoir !",
  "nav": {
    "home": "Accueil",
    "about": "A propos",
    "contact": "Contact"
  },
  "items_count": "Vous avez %{count} articles"
}
```

**locales/de.yml** (YAML also supported):
```yaml
greeting: "Hallo, %{name}!"
goodbye: "Auf Wiedersehen!"
nav:
  home: "Startseite"
  about: "Uber uns"
  contact: "Kontakt"
```

## Using Translations

```ruby
# The t() shortcut is available on the Tina4 module
Tina4.t("greeting", name: "Alice")
# => "Hello, Alice!"

# Nested keys with dot notation
Tina4.t("nav.home")
# => "Home"

# Or use the Localization module directly
Tina4::Localization.t("goodbye")
# => "Goodbye!"
```

## Switching Locale

```ruby
# Set current locale
Tina4::Localization.current_locale = "fr"

Tina4.t("greeting", name: "Alice")
# => "Bonjour, Alice !"

Tina4.t("nav.home")
# => "Accueil"
```

## Locale from Environment

Set the default locale via `.env`:

```
TINA4_LANGUAGE="fr"
```

## Per-Request Locale

```ruby
# Override locale for a specific translation
Tina4.t("greeting", locale: "de", name: "Alice")
# => "Hallo, Alice!"

# Use request header to determine locale
Tina4.get "/welcome" do |request, response|
  locale = request.header("accept_language")&.split(",")&.first&.split("-")&.first || "en"
  message = Tina4.t("greeting", locale: locale, name: "Visitor")
  response.json({ message: message, locale: locale })
end
```

## Fallback Behavior

If a key is not found in the current locale, Tina4 falls back to English (`en`). If still not found, returns the key itself or the provided default.

```ruby
Tina4::Localization.current_locale = "ja"

Tina4.t("greeting", name: "Alice")
# Falls back to English: "Hello, Alice!"

Tina4.t("nonexistent.key")
# => "nonexistent.key" (returns the key)

Tina4.t("nonexistent.key", default: "Default text")
# => "Default text"
```

## Adding Translations Programmatically

```ruby
Tina4::Localization.add("en", "welcome.title", "Welcome to our app")
Tina4::Localization.add("es", "welcome.title", "Bienvenido a nuestra app")

Tina4.t("welcome.title")
# => "Welcome to our app"
```

## Available Locales

```ruby
Tina4::Localization.available_locales
# => ["en", "fr", "de", "es"]
```

## Using in Templates

Set translations as template globals for access in Twig/ERB templates.

```ruby
Tina4.get "/page" do |request, response|
  locale = request.query["lang"] || "en"
  Tina4::Localization.current_locale = locale

  response.render("pages/home.twig", {
    nav_home: Tina4.t("nav.home"),
    nav_about: Tina4.t("nav.about"),
    greeting: Tina4.t("greeting", name: "Visitor")
  })
end
```

Or register a global translation helper:

```ruby
Tina4.template_global("t", ->(key, **opts) { Tina4.t(key, **opts) })
```
