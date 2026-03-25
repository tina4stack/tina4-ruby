# Set Up Tina4 Internationalization (i18n)

Add multi-language support using the built-in Localization module.

## Instructions

1. Create translation files in `src/locales/`
2. Set up the localization instance
3. Use translations in routes and templates

## Translation Files

Create JSON files per language in `src/locales/`:

**`src/locales/en.json`**
```json
{
    "welcome": "Welcome",
    "greeting": "Hello, {name}!",
    "items_count": "{count} item|{count} items",
    "nav": {
        "home": "Home",
        "about": "About",
        "contact": "Contact"
    }
}
```

**`src/locales/fr.json`**
```json
{
    "welcome": "Bienvenue",
    "greeting": "Bonjour, {name} !",
    "items_count": "{count} article|{count} articles",
    "nav": {
        "home": "Accueil",
        "about": "A propos",
        "contact": "Contact"
    }
}
```

## Setup

```ruby
require "tina4/i18n"

I18N = Tina4::I18n.new(default_locale: "en", locales_path: "src/locales")
```

## Usage in Routes

```ruby
require "tina4/router"
require "tina4/i18n"

i18n = Tina4::I18n.new

Tina4::Router.get "/welcome" do |request, response|
  locale = request.params.fetch("lang", "en")
  response.json({
    "message" => i18n.t("welcome", locale: locale),
    "greeting" => i18n.t("greeting", locale: locale, name: "Alice")
  })
end
```

## Usage in Templates

```twig
{# Set locale #}
{% set locale = "fr" %}

{# Simple translation #}
<h1>{{ t("welcome", locale) }}</h1>

{# With parameters #}
<p>{{ t("greeting", locale, name=user.name) }}</p>

{# Nested keys #}
<nav>
    <a href="/">{{ t("nav.home", locale) }}</a>
    <a href="/about">{{ t("nav.about", locale) }}</a>
</nav>

{# Pluralization #}
<p>{{ t("items_count", locale, count=cart.size) }}</p>
```

## Features

```ruby
i18n = Tina4::I18n.new

# Translate
i18n.t("welcome")                             # English (default)
i18n.t("welcome", locale: "fr")               # French
i18n.t("greeting", name: "Alice")             # With interpolation
i18n.t("nav.home")                            # Nested key
i18n.t("items_count", count: 1)               # Singular
i18n.t("items_count", count: 5)               # Plural

# Available locales
i18n.locales                                  # ["en", "fr", "de"]

# Missing key handling
i18n.t("missing.key")                         # Returns "missing.key"
```

## Key Rules

- Translation files are JSON in `src/locales/`
- File name = locale code (e.g., `en.json`, `fr.json`, `pt-BR.json`)
- Use dot notation for nested keys: `"nav.home"`
- Use `{name}` for interpolation parameters
- Use `|` for singular/plural forms
- Detect locale from: query param, header (`Accept-Language`), or session
