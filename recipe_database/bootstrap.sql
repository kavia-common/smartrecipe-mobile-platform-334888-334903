BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "btree_gin";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "unaccent";

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'recipe_visibility') THEN
        CREATE TYPE recipe_visibility AS ENUM ('draft', 'published', 'archived');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'recipe_difficulty') THEN
        CREATE TYPE recipe_difficulty AS ENUM ('easy', 'medium', 'hard');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'meal_slot') THEN
        CREATE TYPE meal_slot AS ENUM ('breakfast', 'lunch', 'dinner', 'snack');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'shopping_list_source') THEN
        CREATE TYPE shopping_list_source AS ENUM ('meal_plan', 'recipe', 'manual');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'shopping_item_status') THEN
        CREATE TYPE shopping_item_status AS ENUM ('pending', 'purchased', 'removed');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'media_kind') THEN
        CREATE TYPE media_kind AS ENUM ('image', 'video');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'analytics_subject_type') THEN
        CREATE TYPE analytics_subject_type AS ENUM ('recipe', 'collection', 'meal_plan', 'shopping_list', 'profile', 'search', 'admin');
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION recipes_search_document(
    recipe_name TEXT,
    recipe_summary TEXT,
    cuisine_label TEXT,
    searchable_ingredients TEXT[]
)
RETURNS tsvector
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT
        setweight(to_tsvector('simple', unaccent(coalesce(recipe_name, ''))), 'A') ||
        setweight(to_tsvector('simple', unaccent(coalesce(recipe_summary, ''))), 'B') ||
        setweight(to_tsvector('simple', unaccent(coalesce(cuisine_label, ''))), 'B') ||
        setweight(to_tsvector('simple', unaccent(array_to_string(coalesce(searchable_ingredients, ARRAY[]::TEXT[]), ' '))), 'C')
$$;

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email CITEXT NOT NULL UNIQUE,
    password_hash TEXT,
    auth_provider TEXT NOT NULL DEFAULT 'email',
    oauth_subject TEXT,
    email_verified_at TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_admin BOOLEAN NOT NULL DEFAULT FALSE,
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT users_auth_provider_check CHECK (char_length(auth_provider) > 0)
);

CREATE TABLE IF NOT EXISTS user_profiles (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    display_name TEXT NOT NULL,
    avatar_url TEXT,
    bio TEXT,
    locale TEXT NOT NULL DEFAULT 'en-US',
    timezone TEXT NOT NULL DEFAULT 'UTC',
    onboarding_completed BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS cuisines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS dietary_tags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL UNIQUE,
    tag_type TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT dietary_tags_type_check CHECK (tag_type IN ('diet', 'allergen', 'preference'))
);

CREATE TABLE IF NOT EXISTS recipe_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS profiles_preferences (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    dietary_tag_ids UUID[] NOT NULL DEFAULT ARRAY[]::UUID[],
    allergen_tag_ids UUID[] NOT NULL DEFAULT ARRAY[]::UUID[],
    disliked_ingredient_names TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    preferred_cuisine_ids UUID[] NOT NULL DEFAULT ARRAY[]::UUID[],
    preferred_difficulty_levels recipe_difficulty[] NOT NULL DEFAULT ARRAY[]::recipe_difficulty[],
    max_prep_minutes INTEGER,
    max_total_minutes INTEGER,
    measurement_system TEXT NOT NULL DEFAULT 'metric',
    voice_assistance_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    large_text_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    email_notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    push_notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT profiles_preferences_measurement_system_check CHECK (measurement_system IN ('metric', 'imperial')),
    CONSTRAINT profiles_preferences_prep_minutes_check CHECK (max_prep_minutes IS NULL OR max_prep_minutes >= 0),
    CONSTRAINT profiles_preferences_total_minutes_check CHECK (max_total_minutes IS NULL OR max_total_minutes >= 0)
);

CREATE TABLE IF NOT EXISTS recipes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    summary TEXT,
    description TEXT,
    visibility recipe_visibility NOT NULL DEFAULT 'draft',
    difficulty recipe_difficulty NOT NULL,
    cuisine_id UUID REFERENCES cuisines(id) ON DELETE SET NULL,
    category_id UUID REFERENCES recipe_categories(id) ON DELETE SET NULL,
    author_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    hero_image_url TEXT,
    hero_image_alt TEXT,
    prep_time_minutes INTEGER NOT NULL DEFAULT 0,
    cook_time_minutes INTEGER NOT NULL DEFAULT 0,
    total_time_minutes INTEGER GENERATED ALWAYS AS (prep_time_minutes + cook_time_minutes) STORED,
    servings NUMERIC(6,2) NOT NULL DEFAULT 1,
    calories_kcal INTEGER,
    protein_grams NUMERIC(8,2),
    carbs_grams NUMERIC(8,2),
    fat_grams NUMERIC(8,2),
    fiber_grams NUMERIC(8,2),
    sugar_grams NUMERIC(8,2),
    sodium_mg NUMERIC(10,2),
    search_ingredient_names TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    search_dietary_slugs TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    search_allergen_slugs TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    search_document TSVECTOR,
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT recipes_title_check CHECK (char_length(title) > 0),
    CONSTRAINT recipes_prep_time_check CHECK (prep_time_minutes >= 0),
    CONSTRAINT recipes_cook_time_check CHECK (cook_time_minutes >= 0),
    CONSTRAINT recipes_servings_check CHECK (servings > 0)
);

CREATE TABLE IF NOT EXISTS recipe_dietary_tags (
    recipe_id UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    tag_id UUID NOT NULL REFERENCES dietary_tags(id) ON DELETE CASCADE,
    PRIMARY KEY (recipe_id, tag_id)
);

CREATE TABLE IF NOT EXISTS recipe_steps (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipe_id UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    step_number INTEGER NOT NULL,
    title TEXT,
    instruction TEXT NOT NULL,
    duration_seconds INTEGER,
    timer_label TEXT,
    voice_hint TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT recipe_steps_number_unique UNIQUE (recipe_id, step_number),
    CONSTRAINT recipe_steps_number_check CHECK (step_number > 0),
    CONSTRAINT recipe_steps_duration_check CHECK (duration_seconds IS NULL OR duration_seconds >= 0)
);

CREATE TABLE IF NOT EXISTS recipe_ingredients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipe_id UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    ingredient_group TEXT NOT NULL DEFAULT 'Main',
    position INTEGER NOT NULL DEFAULT 1,
    ingredient_name TEXT NOT NULL,
    quantity NUMERIC(10,3),
    unit TEXT,
    preparation_note TEXT,
    optional BOOLEAN NOT NULL DEFAULT FALSE,
    pantry BOOLEAN NOT NULL DEFAULT FALSE,
    shopping_category TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT recipe_ingredients_position_check CHECK (position > 0)
);

CREATE TABLE IF NOT EXISTS recipe_media (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipe_id UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    kind media_kind NOT NULL DEFAULT 'image',
    media_url TEXT NOT NULL,
    alt_text TEXT,
    sort_order INTEGER NOT NULL DEFAULT 1,
    width_px INTEGER,
    height_px INTEGER,
    uploaded_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT recipe_media_sort_order_check CHECK (sort_order > 0)
);

CREATE TABLE IF NOT EXISTS favorites (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipe_id UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, recipe_id)
);

CREATE TABLE IF NOT EXISTS collections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    cover_image_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT collections_name_check CHECK (char_length(name) > 0)
);

CREATE TABLE IF NOT EXISTS collection_recipes (
    collection_id UUID NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    recipe_id UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    sort_order INTEGER NOT NULL DEFAULT 1,
    added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (collection_id, recipe_id),
    CONSTRAINT collection_recipes_sort_order_check CHECK (sort_order > 0)
);

CREATE TABLE IF NOT EXISTS meal_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    week_start_date DATE NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT meal_plans_user_week_unique UNIQUE (user_id, week_start_date)
);

CREATE TABLE IF NOT EXISTS meal_plan_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meal_plan_id UUID NOT NULL REFERENCES meal_plans(id) ON DELETE CASCADE,
    recipe_id UUID REFERENCES recipes(id) ON DELETE SET NULL,
    planned_date DATE NOT NULL,
    meal_slot meal_slot NOT NULL,
    servings NUMERIC(6,2) NOT NULL DEFAULT 1,
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT meal_plan_entries_slot_unique UNIQUE (meal_plan_id, planned_date, meal_slot),
    CONSTRAINT meal_plan_entries_servings_check CHECK (servings > 0)
);

CREATE TABLE IF NOT EXISTS shopping_lists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    meal_plan_id UUID REFERENCES meal_plans(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    source shopping_list_source NOT NULL DEFAULT 'manual',
    is_archived BOOLEAN NOT NULL DEFAULT FALSE,
    generated_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS shopping_list_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shopping_list_id UUID NOT NULL REFERENCES shopping_lists(id) ON DELETE CASCADE,
    recipe_id UUID REFERENCES recipes(id) ON DELETE SET NULL,
    meal_plan_entry_id UUID REFERENCES meal_plan_entries(id) ON DELETE SET NULL,
    ingredient_name TEXT NOT NULL,
    quantity NUMERIC(10,3),
    unit TEXT,
    section_name TEXT,
    notes TEXT,
    status shopping_item_status NOT NULL DEFAULT 'pending',
    is_custom BOOLEAN NOT NULL DEFAULT FALSE,
    normalized_key TEXT,
    aggregated_from_count INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT shopping_list_items_aggregated_count_check CHECK (aggregated_from_count > 0)
);

CREATE TABLE IF NOT EXISTS admin_audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    subject_type TEXT NOT NULL,
    subject_id UUID,
    payload JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS analytics_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    session_id UUID,
    event_name TEXT NOT NULL,
    subject_type analytics_subject_type NOT NULL,
    subject_id UUID,
    page_path TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION sync_recipe_search_document()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    cuisine_name TEXT;
BEGIN
    SELECT c.name
    INTO cuisine_name
    FROM cuisines c
    WHERE c.id = NEW.cuisine_id;

    NEW.search_document := recipes_search_document(
        NEW.title,
        NEW.summary,
        cuisine_name,
        NEW.search_ingredient_names
    );

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_set_updated_at ON users;
CREATE TRIGGER trg_users_set_updated_at
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_user_profiles_set_updated_at ON user_profiles;
CREATE TRIGGER trg_user_profiles_set_updated_at
BEFORE UPDATE ON user_profiles
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_profiles_preferences_set_updated_at ON profiles_preferences;
CREATE TRIGGER trg_profiles_preferences_set_updated_at
BEFORE UPDATE ON profiles_preferences
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_recipes_set_updated_at ON recipes;
CREATE TRIGGER trg_recipes_set_updated_at
BEFORE UPDATE ON recipes
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_recipes_search_document ON recipes;
CREATE TRIGGER trg_recipes_search_document
BEFORE INSERT OR UPDATE OF title, summary, cuisine_id, search_ingredient_names ON recipes
FOR EACH ROW
EXECUTE FUNCTION sync_recipe_search_document();

DROP TRIGGER IF EXISTS trg_collections_set_updated_at ON collections;
CREATE TRIGGER trg_collections_set_updated_at
BEFORE UPDATE ON collections
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_meal_plans_set_updated_at ON meal_plans;
CREATE TRIGGER trg_meal_plans_set_updated_at
BEFORE UPDATE ON meal_plans
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_meal_plan_entries_set_updated_at ON meal_plan_entries;
CREATE TRIGGER trg_meal_plan_entries_set_updated_at
BEFORE UPDATE ON meal_plan_entries
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_shopping_lists_set_updated_at ON shopping_lists;
CREATE TRIGGER trg_shopping_lists_set_updated_at
BEFORE UPDATE ON shopping_lists
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_shopping_list_items_set_updated_at ON shopping_list_items;
CREATE TRIGGER trg_shopping_list_items_set_updated_at
BEFORE UPDATE ON shopping_list_items
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE INDEX IF NOT EXISTS idx_users_oauth_subject ON users (oauth_subject);
CREATE INDEX IF NOT EXISTS idx_profiles_preferences_dietary_tags ON profiles_preferences USING GIN (dietary_tag_ids);
CREATE INDEX IF NOT EXISTS idx_profiles_preferences_allergen_tags ON profiles_preferences USING GIN (allergen_tag_ids);
CREATE INDEX IF NOT EXISTS idx_profiles_preferences_preferred_cuisines ON profiles_preferences USING GIN (preferred_cuisine_ids);
CREATE INDEX IF NOT EXISTS idx_profiles_preferences_difficulty_levels ON profiles_preferences USING GIN (preferred_difficulty_levels);

CREATE INDEX IF NOT EXISTS idx_recipes_visibility ON recipes (visibility);
CREATE INDEX IF NOT EXISTS idx_recipes_cuisine_visibility ON recipes (cuisine_id, visibility);
CREATE INDEX IF NOT EXISTS idx_recipes_category_visibility ON recipes (category_id, visibility);
CREATE INDEX IF NOT EXISTS idx_recipes_difficulty_visibility ON recipes (difficulty, visibility);
CREATE INDEX IF NOT EXISTS idx_recipes_total_time_visibility ON recipes (total_time_minutes, visibility);
CREATE INDEX IF NOT EXISTS idx_recipes_published_at ON recipes (published_at DESC);
CREATE INDEX IF NOT EXISTS idx_recipes_title_trgm ON recipes USING GIN (title gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_recipes_summary_trgm ON recipes USING GIN (summary gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_recipes_search_doc ON recipes USING GIN (search_document);
CREATE INDEX IF NOT EXISTS idx_recipes_search_ingredients ON recipes USING GIN (search_ingredient_names);
CREATE INDEX IF NOT EXISTS idx_recipes_search_dietary_slugs ON recipes USING GIN (search_dietary_slugs);
CREATE INDEX IF NOT EXISTS idx_recipes_search_allergen_slugs ON recipes USING GIN (search_allergen_slugs);

CREATE INDEX IF NOT EXISTS idx_recipe_dietary_tags_tag_recipe ON recipe_dietary_tags (tag_id, recipe_id);
CREATE INDEX IF NOT EXISTS idx_recipe_steps_recipe_step_number ON recipe_steps (recipe_id, step_number);
CREATE INDEX IF NOT EXISTS idx_recipe_ingredients_recipe_position ON recipe_ingredients (recipe_id, position);
CREATE INDEX IF NOT EXISTS idx_recipe_ingredients_name_trgm ON recipe_ingredients USING GIN (ingredient_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_recipe_media_recipe_sort_order ON recipe_media (recipe_id, sort_order);

CREATE INDEX IF NOT EXISTS idx_favorites_recipe ON favorites (recipe_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_collections_user_updated_at ON collections (user_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_collection_recipes_recipe ON collection_recipes (recipe_id, added_at DESC);

CREATE INDEX IF NOT EXISTS idx_meal_plans_user_week ON meal_plans (user_id, week_start_date);
CREATE INDEX IF NOT EXISTS idx_meal_plan_entries_plan_date_slot ON meal_plan_entries (meal_plan_id, planned_date, meal_slot);
CREATE INDEX IF NOT EXISTS idx_meal_plan_entries_recipe ON meal_plan_entries (recipe_id);

CREATE INDEX IF NOT EXISTS idx_shopping_lists_user_created_at ON shopping_lists (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_shopping_lists_meal_plan ON shopping_lists (meal_plan_id);
CREATE INDEX IF NOT EXISTS idx_shopping_list_items_list_status ON shopping_list_items (shopping_list_id, status);
CREATE INDEX IF NOT EXISTS idx_shopping_list_items_recipe ON shopping_list_items (recipe_id);
CREATE INDEX IF NOT EXISTS idx_shopping_list_items_normalized_key ON shopping_list_items (normalized_key);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_admin_created_at ON admin_audit_logs (admin_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_subject ON admin_audit_logs (subject_type, subject_id);

CREATE INDEX IF NOT EXISTS idx_analytics_events_user_occurred_at ON analytics_events (user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_analytics_events_name_occurred_at ON analytics_events (event_name, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_analytics_events_subject ON analytics_events (subject_type, subject_id);
CREATE INDEX IF NOT EXISTS idx_analytics_events_metadata ON analytics_events USING GIN (metadata);

CREATE OR REPLACE VIEW recipe_search_view AS
SELECT
    r.id,
    r.slug,
    r.title,
    r.summary,
    r.visibility,
    r.difficulty,
    r.prep_time_minutes,
    r.cook_time_minutes,
    r.total_time_minutes,
    r.servings,
    r.hero_image_url,
    r.calories_kcal,
    c.name AS cuisine_name,
    c.slug AS cuisine_slug,
    cat.name AS category_name,
    cat.slug AS category_slug,
    ARRAY_REMOVE(ARRAY_AGG(DISTINCT dt.slug) FILTER (WHERE dt.tag_type = 'diet'), NULL) AS diet_slugs,
    ARRAY_REMOVE(ARRAY_AGG(DISTINCT dt.slug) FILTER (WHERE dt.tag_type = 'allergen'), NULL) AS allergen_slugs,
    COUNT(DISTINCT f.user_id) AS favorite_count
FROM recipes r
LEFT JOIN cuisines c ON c.id = r.cuisine_id
LEFT JOIN recipe_categories cat ON cat.id = r.category_id
LEFT JOIN recipe_dietary_tags rdt ON rdt.recipe_id = r.id
LEFT JOIN dietary_tags dt ON dt.id = rdt.tag_id
LEFT JOIN favorites f ON f.recipe_id = r.id
GROUP BY
    r.id, c.name, c.slug, cat.name, cat.slug;

INSERT INTO cuisines (slug, name, description)
VALUES
    ('mediterranean', 'Mediterranean', 'Fresh and vibrant dishes inspired by Mediterranean cooking.'),
    ('mexican', 'Mexican', 'Flavor-forward meals with spices, herbs, and bright toppings.'),
    ('american', 'American', 'Comfort food and weeknight staples.'),
    ('asian', 'Asian', 'Broad set of East and Southeast Asian-inspired flavors.')
ON CONFLICT (slug) DO NOTHING;

INSERT INTO recipe_categories (slug, name, description)
VALUES
    ('breakfast', 'Breakfast', 'Morning meals and brunch favorites.'),
    ('dinner', 'Dinner', 'Family dinners and evening meals.'),
    ('lunch', 'Lunch', 'Quick lunches and meal-prep friendly dishes.'),
    ('dessert', 'Dessert', 'Sweet treats and celebratory bakes.')
ON CONFLICT (slug) DO NOTHING;

INSERT INTO dietary_tags (slug, name, tag_type, description)
VALUES
    ('vegetarian', 'Vegetarian', 'diet', 'Contains no meat or seafood.'),
    ('vegan', 'Vegan', 'diet', 'Contains no animal products.'),
    ('gluten-free', 'Gluten Free', 'diet', 'Prepared without gluten-containing ingredients.'),
    ('high-protein', 'High Protein', 'preference', 'Higher protein recipe option.'),
    ('dairy', 'Dairy', 'allergen', 'Contains milk-based ingredients.'),
    ('nuts', 'Tree Nuts', 'allergen', 'Contains tree nuts.'),
    ('shellfish', 'Shellfish', 'allergen', 'Contains shellfish.')
ON CONFLICT (slug) DO NOTHING;

INSERT INTO users (id, email, password_hash, auth_provider, email_verified_at, is_active, is_admin, last_login_at)
VALUES
    ('00000000-0000-0000-0000-000000000001', 'admin@smartrecipe.app', '$2b$12$adminseedplaceholderhash', 'email', NOW(), TRUE, TRUE, NOW()),
    ('00000000-0000-0000-0000-000000000002', 'alex@smartrecipe.app', '$2b$12$userseedplaceholderhash', 'email', NOW(), TRUE, FALSE, NOW()),
    ('00000000-0000-0000-0000-000000000003', 'jamie@smartrecipe.app', NULL, 'google', NOW(), TRUE, FALSE, NOW())
ON CONFLICT (id) DO NOTHING;

INSERT INTO user_profiles (user_id, display_name, avatar_url, bio, locale, timezone, onboarding_completed)
VALUES
    ('00000000-0000-0000-0000-000000000001', 'SmartRecipe Admin', 'https://images.unsplash.com/photo-1542909168-82c3e7fdca5c?auto=format&fit=crop&w=300&q=80', 'Curates recipe content and editorial picks.', 'en-US', 'UTC', TRUE),
    ('00000000-0000-0000-0000-000000000002', 'Alex Rivera', 'https://images.unsplash.com/photo-1546961329-78bef0414d7c?auto=format&fit=crop&w=300&q=80', 'Busy home cook focused on fast dinners.', 'en-US', 'America/New_York', TRUE),
    ('00000000-0000-0000-0000-000000000003', 'Jamie Chen', 'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?auto=format&fit=crop&w=300&q=80', 'Meal planner and weekend batch cooker.', 'en-US', 'America/Los_Angeles', TRUE)
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO profiles_preferences (
    user_id,
    dietary_tag_ids,
    allergen_tag_ids,
    disliked_ingredient_names,
    preferred_cuisine_ids,
    preferred_difficulty_levels,
    max_prep_minutes,
    max_total_minutes,
    measurement_system,
    voice_assistance_enabled,
    large_text_enabled
)
VALUES
(
    '00000000-0000-0000-0000-000000000002',
    ARRAY[(SELECT id FROM dietary_tags WHERE slug = 'vegetarian')],
    ARRAY[(SELECT id FROM dietary_tags WHERE slug = 'nuts')],
    ARRAY['cilantro'],
    ARRAY[(SELECT id FROM cuisines WHERE slug = 'mediterranean')],
    ARRAY['easy'::recipe_difficulty, 'medium'::recipe_difficulty],
    20,
    40,
    'metric',
    TRUE,
    FALSE
),
(
    '00000000-0000-0000-0000-000000000003',
    ARRAY[(SELECT id FROM dietary_tags WHERE slug = 'gluten-free')],
    ARRAY[(SELECT id FROM dietary_tags WHERE slug = 'shellfish')],
    ARRAY['blue cheese'],
    ARRAY[(SELECT id FROM cuisines WHERE slug = 'asian'), (SELECT id FROM cuisines WHERE slug = 'mexican')],
    ARRAY['easy'::recipe_difficulty],
    15,
    35,
    'imperial',
    FALSE,
    TRUE
)
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO recipes (
    id,
    slug,
    title,
    summary,
    description,
    visibility,
    difficulty,
    cuisine_id,
    category_id,
    author_user_id,
    hero_image_url,
    hero_image_alt,
    prep_time_minutes,
    cook_time_minutes,
    servings,
    calories_kcal,
    protein_grams,
    carbs_grams,
    fat_grams,
    fiber_grams,
    sugar_grams,
    sodium_mg,
    search_ingredient_names,
    search_dietary_slugs,
    search_allergen_slugs,
    published_at
)
VALUES
(
    '10000000-0000-0000-0000-000000000001',
    'mediterranean-chickpea-bowls',
    'Mediterranean Chickpea Bowls',
    'A bright grain bowl with lemony chickpeas, cucumbers, herbs, and creamy yogurt sauce.',
    'Meal-prep friendly bowls with fresh vegetables, protein-rich chickpeas, and quick homemade dressing.',
    'published',
    'easy',
    (SELECT id FROM cuisines WHERE slug = 'mediterranean'),
    (SELECT id FROM recipe_categories WHERE slug = 'lunch'),
    '00000000-0000-0000-0000-000000000001',
    'https://images.unsplash.com/photo-1547592180-85f173990554?auto=format&fit=crop&w=1200&q=80',
    'Mediterranean grain bowl with chickpeas and vegetables.',
    15,
    10,
    4,
    420,
    17,
    48,
    14,
    11,
    8,
    560,
    ARRAY['chickpeas', 'cucumber', 'tomato', 'quinoa', 'yogurt', 'lemon', 'parsley'],
    ARRAY['vegetarian'],
    ARRAY['dairy'],
    NOW()
),
(
    '10000000-0000-0000-0000-000000000002',
    'sheet-pan-fajita-chicken',
    'Sheet Pan Fajita Chicken',
    'Weeknight chicken fajitas roasted on one pan with peppers and onions.',
    'Minimal cleanup and bold flavor make this a reliable dinner for busy schedules.',
    'published',
    'easy',
    (SELECT id FROM cuisines WHERE slug = 'mexican'),
    (SELECT id FROM recipe_categories WHERE slug = 'dinner'),
    '00000000-0000-0000-0000-000000000001',
    'https://images.unsplash.com/photo-1513456852971-30c0b8199d4d?auto=format&fit=crop&w=1200&q=80',
    'Sheet pan chicken fajitas with peppers and onions.',
    10,
    22,
    4,
    390,
    32,
    18,
    17,
    5,
    7,
    710,
    ARRAY['chicken breast', 'bell pepper', 'onion', 'lime', 'garlic', 'chili powder', 'tortillas'],
    ARRAY['high-protein'],
    ARRAY[]::TEXT[],
    NOW()
),
(
    '10000000-0000-0000-0000-000000000003',
    'ginger-garlic-noodle-stir-fry',
    'Ginger Garlic Noodle Stir-Fry',
    'Saucy noodles tossed with crisp vegetables and a gingery garlic glaze.',
    'Fast stir-fry that works for pantry dinners and can be customized with any vegetables on hand.',
    'published',
    'medium',
    (SELECT id FROM cuisines WHERE slug = 'asian'),
    (SELECT id FROM recipe_categories WHERE slug = 'dinner'),
    '00000000-0000-0000-0000-000000000001',
    'https://images.unsplash.com/photo-1617093727343-374698b1b08d?auto=format&fit=crop&w=1200&q=80',
    'Vegetable noodle stir fry in a bowl.',
    12,
    14,
    3,
    510,
    14,
    76,
    16,
    7,
    10,
    980,
    ARRAY['rice noodles', 'broccoli', 'carrot', 'garlic', 'ginger', 'soy sauce', 'sesame oil'],
    ARRAY['vegan'],
    ARRAY[]::TEXT[],
    NOW()
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO recipe_dietary_tags (recipe_id, tag_id)
VALUES
    ('10000000-0000-0000-0000-000000000001', (SELECT id FROM dietary_tags WHERE slug = 'vegetarian')),
    ('10000000-0000-0000-0000-000000000001', (SELECT id FROM dietary_tags WHERE slug = 'dairy')),
    ('10000000-0000-0000-0000-000000000002', (SELECT id FROM dietary_tags WHERE slug = 'high-protein')),
    ('10000000-0000-0000-0000-000000000003', (SELECT id FROM dietary_tags WHERE slug = 'vegan')),
    ('10000000-0000-0000-0000-000000000003', (SELECT id FROM dietary_tags WHERE slug = 'gluten-free'))
ON CONFLICT DO NOTHING;

INSERT INTO recipe_steps (recipe_id, step_number, title, instruction, duration_seconds, timer_label, voice_hint)
VALUES
    ('10000000-0000-0000-0000-000000000001', 1, 'Cook the quinoa', 'Rinse the quinoa, combine with water, and simmer until fluffy.', 900, 'Quinoa timer', 'Stir once halfway through for even cooking.'),
    ('10000000-0000-0000-0000-000000000001', 2, 'Season the chickpeas', 'Toss chickpeas with olive oil, lemon zest, salt, and oregano.', 180, NULL, 'Taste and adjust lemon before serving.'),
    ('10000000-0000-0000-0000-000000000001', 3, 'Assemble bowls', 'Layer quinoa, vegetables, chickpeas, and yogurt sauce. Finish with herbs.', 240, NULL, 'Keep toppings separate for meal prep.'),
    ('10000000-0000-0000-0000-000000000002', 1, 'Prep the pan', 'Heat oven to 425°F and line a sheet pan for easy cleanup.', 300, 'Oven preheat', 'Use convection if available for better browning.'),
    ('10000000-0000-0000-0000-000000000002', 2, 'Season chicken and vegetables', 'Coat the sliced chicken, peppers, and onions with oil and fajita spices.', 240, NULL, 'Spread everything in an even layer.'),
    ('10000000-0000-0000-0000-000000000002', 3, 'Roast', 'Roast until the chicken is cooked through and vegetables are tender.', 1320, 'Roasting timer', 'Broil for 1 to 2 minutes if you want charred edges.'),
    ('10000000-0000-0000-0000-000000000003', 1, 'Boil noodles', 'Cook noodles according to package directions, then rinse briefly.', 420, 'Noodle timer', 'Undercook by one minute so they finish in the sauce.'),
    ('10000000-0000-0000-0000-000000000003', 2, 'Build the sauce', 'Whisk soy sauce, garlic, ginger, maple syrup, and sesame oil.', 180, NULL, 'Keep sauce nearby before stir-frying.'),
    ('10000000-0000-0000-0000-000000000003', 3, 'Stir-fry vegetables and noodles', 'Cook vegetables until crisp-tender, add noodles and sauce, then toss until glossy.', 480, 'Stir-fry timer', 'Serve immediately for best texture.')
ON CONFLICT DO NOTHING;

INSERT INTO recipe_ingredients (
    recipe_id,
    ingredient_group,
    position,
    ingredient_name,
    quantity,
    unit,
    preparation_note,
    optional,
    pantry,
    shopping_category
)
VALUES
    ('10000000-0000-0000-0000-000000000001', 'Bowl', 1, 'Quinoa', 1.000, 'cup', 'Rinsed', FALSE, TRUE, 'Grains'),
    ('10000000-0000-0000-0000-000000000001', 'Bowl', 2, 'Chickpeas', 2.000, 'can', 'Drained and rinsed', FALSE, TRUE, 'Canned Goods'),
    ('10000000-0000-0000-0000-000000000001', 'Bowl', 3, 'Cucumber', 1.000, NULL, 'Diced', FALSE, FALSE, 'Produce'),
    ('10000000-0000-0000-0000-000000000001', 'Bowl', 4, 'Cherry tomatoes', 1.500, 'cups', 'Halved', FALSE, FALSE, 'Produce'),
    ('10000000-0000-0000-0000-000000000001', 'Sauce', 5, 'Greek yogurt', 0.750, 'cup', NULL, FALSE, FALSE, 'Dairy'),
    ('10000000-0000-0000-0000-000000000001', 'Sauce', 6, 'Lemon', 1.000, NULL, 'Zested and juiced', FALSE, FALSE, 'Produce'),
    ('10000000-0000-0000-0000-000000000002', 'Main', 1, 'Chicken breast', 1.500, 'lb', 'Thinly sliced', FALSE, FALSE, 'Meat'),
    ('10000000-0000-0000-0000-000000000002', 'Main', 2, 'Bell peppers', 3.000, NULL, 'Sliced', FALSE, FALSE, 'Produce'),
    ('10000000-0000-0000-0000-000000000002', 'Main', 3, 'Yellow onion', 1.000, NULL, 'Sliced', FALSE, FALSE, 'Produce'),
    ('10000000-0000-0000-0000-000000000002', 'Pantry', 4, 'Chili powder', 2.000, 'tbsp', NULL, FALSE, TRUE, 'Spices'),
    ('10000000-0000-0000-0000-000000000002', 'Serve', 5, 'Flour tortillas', 8.000, NULL, 'Warm before serving', TRUE, FALSE, 'Bakery'),
    ('10000000-0000-0000-0000-000000000003', 'Noodles', 1, 'Rice noodles', 8.000, 'oz', NULL, FALSE, FALSE, 'Dry Goods'),
    ('10000000-0000-0000-0000-000000000003', 'Vegetables', 2, 'Broccoli florets', 3.000, 'cups', NULL, FALSE, FALSE, 'Produce'),
    ('10000000-0000-0000-0000-000000000003', 'Vegetables', 3, 'Carrot', 2.000, NULL, 'Julienned', FALSE, FALSE, 'Produce'),
    ('10000000-0000-0000-0000-000000000003', 'Sauce', 4, 'Soy sauce', 0.250, 'cup', 'Use tamari if needed', FALSE, TRUE, 'Condiments'),
    ('10000000-0000-0000-0000-000000000003', 'Sauce', 5, 'Fresh ginger', 1.000, 'tbsp', 'Grated', FALSE, FALSE, 'Produce')
ON CONFLICT DO NOTHING;

INSERT INTO recipe_media (
    recipe_id,
    kind,
    media_url,
    alt_text,
    sort_order,
    width_px,
    height_px,
    uploaded_by_user_id
)
VALUES
    ('10000000-0000-0000-0000-000000000001', 'image', 'https://images.unsplash.com/photo-1547592180-85f173990554?auto=format&fit=crop&w=1200&q=80', 'Mediterranean chickpea bowl close-up.', 1, 1200, 800, '00000000-0000-0000-0000-000000000001'),
    ('10000000-0000-0000-0000-000000000002', 'image', 'https://images.unsplash.com/photo-1513456852971-30c0b8199d4d?auto=format&fit=crop&w=1200&q=80', 'Chicken fajitas served on tortillas.', 1, 1200, 800, '00000000-0000-0000-0000-000000000001'),
    ('10000000-0000-0000-0000-000000000003', 'image', 'https://images.unsplash.com/photo-1617093727343-374698b1b08d?auto=format&fit=crop&w=1200&q=80', 'Noodle stir fry in a serving bowl.', 1, 1200, 800, '00000000-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;

INSERT INTO favorites (user_id, recipe_id)
VALUES
    ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001'),
    ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002'),
    ('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003')
ON CONFLICT DO NOTHING;

INSERT INTO collections (id, user_id, name, description, is_default, cover_image_url)
VALUES
    ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'Weeknight Winners', 'Fast dinners for busy weekdays.', FALSE, 'https://images.unsplash.com/photo-1512621776951-a57141f2eefd?auto=format&fit=crop&w=600&q=80'),
    ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 'Meal Prep Favorites', 'Recipes that scale well for lunch leftovers.', TRUE, 'https://images.unsplash.com/photo-1490645935967-10de6ba17061?auto=format&fit=crop&w=600&q=80')
ON CONFLICT (id) DO NOTHING;

INSERT INTO collection_recipes (collection_id, recipe_id, sort_order)
VALUES
    ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 1),
    ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 2),
    ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 1),
    ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003', 2)
ON CONFLICT DO NOTHING;

INSERT INTO meal_plans (id, user_id, title, week_start_date, notes)
VALUES
    ('30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'This Week''s Plan', DATE '2026-03-16', 'Focus on quick dinners and leftovers for lunch.'),
    ('30000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 'Balanced Week', DATE '2026-03-16', 'Keep prep light during weekdays.')
ON CONFLICT (id) DO NOTHING;

INSERT INTO meal_plan_entries (id, meal_plan_id, recipe_id, planned_date, meal_slot, servings, note)
VALUES
    ('31000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', DATE '2026-03-17', 'lunch', 2, 'Pack leftovers in containers.'),
    ('31000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', DATE '2026-03-18', 'dinner', 4, 'Warm tortillas just before serving.'),
    ('31000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003', DATE '2026-03-19', 'dinner', 3, 'Double the vegetables if needed.')
ON CONFLICT (id) DO NOTHING;

INSERT INTO shopping_lists (id, user_id, meal_plan_id, title, source, is_archived, generated_at)
VALUES
    ('40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001', 'Weeknight Grocery Run', 'meal_plan', FALSE, NOW()),
    ('40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', NULL, 'Custom Weekend List', 'manual', FALSE, NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO shopping_list_items (
    id,
    shopping_list_id,
    recipe_id,
    meal_plan_entry_id,
    ingredient_name,
    quantity,
    unit,
    section_name,
    notes,
    status,
    is_custom,
    normalized_key,
    aggregated_from_count
)
VALUES
    ('41000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '31000000-0000-0000-0000-000000000001', 'Cucumber', 1.000, NULL, 'Produce', 'For the chickpea bowls.', 'pending', FALSE, 'cucumber', 1),
    ('41000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', '31000000-0000-0000-0000-000000000002', 'Bell peppers', 3.000, NULL, 'Produce', NULL, 'pending', FALSE, 'bell-peppers', 1),
    ('41000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000001', NULL, NULL, 'Sparkling water', 2.000, 'bottle', 'Beverages', 'Manual add-on.', 'purchased', TRUE, 'sparkling-water', 1),
    ('41000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000002', NULL, NULL, 'Blueberries', 2.000, 'pint', 'Produce', NULL, 'pending', TRUE, 'blueberries', 1)
ON CONFLICT (id) DO NOTHING;

INSERT INTO admin_audit_logs (admin_user_id, action, subject_type, subject_id, payload)
VALUES
    ('00000000-0000-0000-0000-000000000001', 'recipe.publish', 'recipe', '10000000-0000-0000-0000-000000000001', '{"source":"seed","notes":"Initial content publication"}'::JSONB),
    ('00000000-0000-0000-0000-000000000001', 'recipe.media.attach', 'recipe', '10000000-0000-0000-0000-000000000002', '{"count":1}'::JSONB)
ON CONFLICT DO NOTHING;

INSERT INTO analytics_events (user_id, session_id, event_name, subject_type, subject_id, page_path, metadata, occurred_at)
VALUES
    ('00000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000001', 'recipe_viewed', 'recipe', '10000000-0000-0000-0000-000000000001', '/recipes/mediterranean-chickpea-bowls', '{"source":"search","device":"mobile"}'::JSONB, NOW() - INTERVAL '1 day'),
    ('00000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000001', 'favorite_added', 'recipe', '10000000-0000-0000-0000-000000000002', '/recipes/sheet-pan-fajita-chicken', '{"source":"recipe_detail"}'::JSONB, NOW() - INTERVAL '20 hours'),
    ('00000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000002', 'shopping_list_generated', 'shopping_list', '40000000-0000-0000-0000-000000000001', '/shopping-lists/40000000-0000-0000-0000-000000000001', '{"item_count":3}'::JSONB, NOW() - INTERVAL '12 hours'),
    (NULL, '50000000-0000-0000-0000-000000000003', 'search_performed', 'search', NULL, '/discover', '{"query":"quick dinner","filters":{"difficulty":["easy"],"max_total_minutes":35}}'::JSONB, NOW() - INTERVAL '2 hours')
ON CONFLICT DO NOTHING;

COMMIT;
