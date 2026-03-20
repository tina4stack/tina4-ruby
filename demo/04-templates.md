# Templates

Tina4 Ruby includes a Twig-compatible template engine and ERB support. Templates are resolved from `templates/`, `src/templates/`, `src/views/`, or `views/` directories. The Twig engine supports variables, filters, loops, conditionals, includes, extends/blocks, and set directives.

## Rendering Templates

```ruby
# From a route handler
Tina4.get "/page" do |request, response|
  response.render("pages/home.twig", { title: "Home", user: "Alice" })
end

# Direct render
html = Tina4::Template.render("pages/home.twig", { title: "Home" })
```

## Template Globals

Set variables available in every template render.

```ruby
Tina4.template_global("app_name", "My App")
Tina4.template_global("version", "1.0.0")

# Or directly
Tina4::Template.add_global("year", Time.now.year)
```

## Variables

```twig
<h1>Hello, {{ name }}!</h1>
<p>You are {{ age }} years old.</p>

{# Nested access #}
<p>{{ user.email }}</p>
<p>{{ items[0] }}</p>

{# String concatenation with ~ #}
<p>{{ first_name ~ " " ~ last_name }}</p>

{# Math #}
<p>Total: {{ price * quantity }}</p>
```

## Filters

Twig filters transform output. Chain them with `|`.

```twig
{{ name | upper }}            {# "ALICE" #}
{{ name | lower }}            {# "alice" #}
{{ name | capitalize }}       {# "Alice" #}
{{ title | title }}           {# "My Great Title" #}
{{ text | trim }}             {# strip whitespace #}
{{ items | length }}          {# 5 #}
{{ items | reverse }}         {# reversed array #}
{{ items | first }}           {# first element #}
{{ items | last }}            {# last element #}
{{ items | join(", ") }}      {# "a, b, c" #}
{{ items | sort }}            {# sorted array #}

{{ bio | default("No bio") }}   {# fallback if nil/empty #}
{{ html | escape }}             {# HTML-escape #}
{{ html | e }}                  {# alias for escape #}
{{ text | nl2br }}              {# newlines to <br> #}
{{ text | striptags }}          {# strip HTML tags #}

{{ price | number_format(2) }}  {# "19.99" #}
{{ price | abs }}               {# absolute value #}
{{ price | round(1) }}          {# round to 1 decimal #}

{{ name | url_encode }}         {# URL-encode #}
{{ data | json_encode }}        {# JSON string #}
{{ text | slice(0, 10) }}       {# substring #}

{{ created_at | date("%Y-%m-%d") }}       {# date formatting #}
{{ items | batch(3) }}                     {# chunk into groups of 3 #}
{{ config | keys }}                        {# hash keys #}
{{ config | values }}                      {# hash values #}
{{ defaults | merge(overrides) }}          {# merge hashes #}
{{ content | raw }}                        {# no escaping #}
```

## Conditionals

```twig
{% if user %}
  <p>Welcome, {{ user.name }}!</p>
{% else %}
  <p>Please log in.</p>
{% endif %}

{% if age >= 18 and active %}
  <p>Active adult user</p>
{% endif %}

{% if role == "admin" %}
  <p>Admin panel</p>
{% elseif role == "editor" %}
  <p>Editor dashboard</p>
{% else %}
  <p>Regular user</p>
{% endif %}

{# Operators: ==, !=, >, <, >=, <=, and, or, not #}
{# Tests: is defined, is empty, in #}

{% if description is empty %}
  <p>No description provided.</p>
{% endif %}

{% if title is defined %}
  <h1>{{ title }}</h1>
{% endif %}

{% if "admin" in roles %}
  <p>Has admin role</p>
{% endif %}
```

## For Loops

```twig
{% for item in items %}
  <li>{{ item.name }} - ${{ item.price }}</li>
{% endfor %}

{# Loop variable #}
{% for user in users %}
  <tr class="{{ loop.index0 % 2 == 0 ? 'even' : 'odd' }}">
    <td>{{ loop.index }}</td>     {# 1-based index #}
    <td>{{ loop.index0 }}</td>    {# 0-based index #}
    <td>{{ user.name }}</td>
    {% if loop.first %}<td>FIRST</td>{% endif %}
    {% if loop.last %}<td>LAST</td>{% endif %}
  </tr>
{% endfor %}

{# Key-value iteration #}
{% for key, value in config %}
  <dt>{{ key }}</dt>
  <dd>{{ value }}</dd>
{% endfor %}

{# Range #}
{% for i in 1..5 %}
  <span>{{ i }}</span>
{% endfor %}
```

## Set Variables

```twig
{% set greeting = "Hello" %}
{% set full_name = first_name ~ " " ~ last_name %}
<p>{{ greeting }}, {{ full_name }}!</p>
```

## Template Inheritance

**templates/base.twig:**
```twig
<!DOCTYPE html>
<html>
<head>
  <title>{% block title %}Default Title{% endblock %}</title>
  {% block head %}{% endblock %}
</head>
<body>
  {% block content %}{% endblock %}
  {% block scripts %}{% endblock %}
</body>
</html>
```

**templates/pages/home.twig:**
```twig
{% extends "base.twig" %}

{% block title %}Home - {{ app_name }}{% endblock %}

{% block content %}
  <h1>Welcome to {{ app_name }}</h1>
  <p>{{ message }}</p>
{% endblock %}
```

## Includes

```twig
{% include "partials/navbar.twig" %}

<main>
  {{ content }}
</main>

{% include "partials/footer.twig" %}
```

## Comments

```twig
{# This is a comment -- not rendered in output #}
```

## ERB Templates

Files with `.erb` extension use Ruby's ERB engine.

```erb
<h1>Hello, <%= name %></h1>

<% if items.any? %>
  <ul>
    <% items.each do |item| %>
      <li><%= item %></li>
    <% end %>
  </ul>
<% end %>
```

Render ERB from a route:

```ruby
Tina4.get "/erb-page" do |request, response|
  response.render("pages/home.erb", { name: "Alice", items: %w[one two three] })
end
```

## Error Templates

Custom error pages go in `templates/errors/`:

```
templates/errors/404.twig
templates/errors/403.twig
templates/errors/500.twig
```

The framework falls back to built-in error templates if custom ones are not found.
