# Recipe Database

This PostgreSQL container provides the full relational data layer for the SmartRecipe application.

## Canonical bootstrap flow

The canonical database bootstrap entrypoint is:

- `startup.sh` → starts PostgreSQL, ensures database/user access, and applies `bootstrap.sql`

This is the single reusable initialization flow for the container. It is designed to be idempotent so the database can be reinitialized safely in local and CI-like environments.

## What the schema supports

The schema covers the PRD feature set:

- authentication-ready `users`
- synced `user_profiles`
- `profiles_preferences` for dietary preferences, allergens, difficulty, time, and accessibility settings
- `recipes` with search/filter metadata, nutrition, timing, servings, and publishing state
- `recipe_steps`, `recipe_ingredients`, and `recipe_media`
- `favorites`
- `collections` and `collection_recipes`
- `meal_plans` and `meal_plan_entries`
- `shopping_lists` and `shopping_list_items`
- `admin_audit_logs`
- `analytics_events`
- `recipe_search_view` for efficient browse/search list queries

## Search/query support

The schema includes indexes for primary user flows:

- trigram search on recipe titles and summaries
- full-text search document on recipe title, summary, cuisine, and searchable ingredient names
- GIN indexes for ingredient and dietary metadata arrays
- meal planning and shopping list indexes for user/date-driven queries
- analytics and admin indexes for reporting/audit inspection

## Seed data

`bootstrap.sql` includes representative seed data for:

- cuisines
- categories
- dietary/allergen tags
- admin and sample users
- profiles and preferences
- published recipes
- ingredients and steps
- favorites and collections
- meal plans and shopping lists
- admin audit logs
- analytics events

## Operational notes

- Connection details are written to `db_connection.txt`.
- The database visualizer reads the generated `db_visualizer/postgres.env`.
- The bootstrap script is idempotent and may be rerun.

## Backend integration contract

The backend should treat this schema as the canonical storage contract.

Key invariants:

- `recipes.visibility = 'published'` should be used for public discovery flows.
- `recipe_steps.step_number` is ordered and unique per recipe.
- `meal_plan_entries` are unique per `(meal_plan_id, planned_date, meal_slot)`.
- `shopping_list_items.normalized_key` is intended for aggregation/grouping logic.
- `analytics_events.metadata` is flexible JSONB for analytics payload evolution.
