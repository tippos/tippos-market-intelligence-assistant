-- Editable starting taxonomy. No row below is presented as measured demand.

INSERT INTO market_intelligence.languages
  (code, english_name, native_name, text_direction, product_status, estimated_localization_cost, notes)
VALUES
  ('und', 'Undetermined', 'Undetermined', 'ltr', 'not_evaluated', NULL, 'Temporary classification for observations that require language enrichment'),
  ('en', 'English', 'English', 'ltr', 'supported', 0, 'Already present in the product'),
  ('es', 'Spanish', 'Español', 'ltr', 'supported', 0, 'Already present in the product'),
  ('fr', 'French', 'Français', 'ltr', 'researching', 4200, 'Candidate market'),
  ('de', 'German', 'Deutsch', 'ltr', 'researching', 4600, 'Candidate market'),
  ('pt', 'Portuguese', 'Português', 'ltr', 'researching', 4200, 'Candidate market'),
  ('it', 'Italian', 'Italiano', 'ltr', 'researching', 4000, 'Candidate market'),
  ('nl', 'Dutch', 'Nederlands', 'ltr', 'researching', 3800, 'Candidate market'),
  ('ar', 'Arabic', 'العربية', 'rtl', 'researching', 6500, 'Requires RTL product validation'),
  ('he', 'Hebrew', 'עברית', 'rtl', 'researching', 5800, 'Requires RTL product validation'),
  ('ja', 'Japanese', '日本語', 'ltr', 'researching', 7200, 'Requires product and payment-market validation')
ON CONFLICT (code) DO UPDATE SET
  english_name = EXCLUDED.english_name,
  native_name = EXCLUDED.native_name,
  text_direction = EXCLUDED.text_direction,
  notes = EXCLUDED.notes,
  updated_at = now();

INSERT INTO market_intelligence.language_rollout_readiness
  (language_code, product_copy_status, legal_copy_status, payment_market_status,
   native_review_status, rtl_validation_status, seo_content_status, blocking_reasons)
SELECT code,
  CASE WHEN product_status = 'supported' THEN 'ready' ELSE 'not_started' END,
  CASE WHEN product_status = 'supported' THEN 'ready' ELSE 'not_started' END,
  CASE WHEN product_status = 'supported' THEN 'supported' ELSE 'not_evaluated' END,
  CASE WHEN product_status = 'supported' THEN 'approved' ELSE 'not_started' END,
  CASE WHEN text_direction = 'rtl' AND product_status <> 'supported' THEN 'not_started' ELSE 'not_required' END,
  CASE WHEN product_status = 'supported' THEN 'ready' ELSE 'not_started' END,
  CASE WHEN product_status = 'supported' THEN '[]'::jsonb ELSE '["awaiting_market_evidence"]'::jsonb END
FROM market_intelligence.languages
WHERE code <> 'und'
ON CONFLICT (language_code) DO NOTHING;

INSERT INTO market_intelligence.sources
  (source_key, display_name, kind, status, collection_method, data_nature, default_confidence, retention_days)
VALUES
  ('manual_csv', 'Reviewed CSV import', 'manual_import', 'enabled', 'manual', 'third_party', 0.750, 730),
  ('synthetic_fixture', 'Synthetic test fixture', 'synthetic', 'mock', 'mock', 'synthetic', 0.300, 30),
  ('google_search_console', 'Google Search Console', 'search_console', 'disabled_pending_credentials', 'official_api', 'measured', 0.950, 730),
  ('bing_webmaster', 'Bing Webmaster Tools', 'search_console', 'disabled_pending_credentials', 'official_api', 'measured', 0.900, 730),
  ('first_party_analytics', 'TIPPOS first-party analytics', 'analytics', 'paused', 'first_party', 'measured', 0.950, 730),
  ('internal_search', 'TIPPOS internal search', 'internal_search', 'paused', 'first_party', 'measured', 0.950, 365),
  ('openai_visibility', 'OpenAI visibility monitor', 'ai_provider', 'disabled_pending_credentials', 'official_api', 'measured', 0.800, 365),
  ('gemini_visibility', 'Gemini visibility monitor', 'ai_provider', 'disabled_pending_credentials', 'official_api', 'measured', 0.800, 365),
  ('anthropic_visibility', 'Anthropic visibility monitor', 'ai_provider', 'disabled_pending_credentials', 'official_api', 'measured', 0.800, 365),
  ('perplexity_visibility', 'Perplexity visibility monitor', 'ai_provider', 'disabled_pending_credentials', 'official_api', 'measured', 0.800, 365)
ON CONFLICT (source_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  kind = EXCLUDED.kind,
  collection_method = EXCLUDED.collection_method,
  data_nature = EXCLUDED.data_nature,
  updated_at = now();

UPDATE market_intelligence.sources
   SET documentation_url = 'https://developers.google.com/webmaster-tools/v1/searchanalytics/query',
       terms_url = 'https://developers.google.com/terms/site-terms'
 WHERE source_key = 'google_search_console';

INSERT INTO market_intelligence.topics (slug, name, description)
VALUES
  ('digital-tipping', 'Digital tipping', 'Cashless and contactless tipping'),
  ('tipping-etiquette', 'Tipping etiquette', 'How much and when to tip'),
  ('hospitality', 'Hospitality', 'Hotels, housekeeping and guest services'),
  ('restaurants', 'Restaurants', 'Servers, bars and food service'),
  ('transport', 'Transport', 'Valet, drivers and delivery'),
  ('wellness', 'Wellness', 'Spa and personal services'),
  ('recipient-tools', 'Recipient tools', 'Ways for workers to receive and cash out tips'),
  ('business-solutions', 'Business solutions', 'Tipping platforms for employers and venues')
ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, updated_at = now();

INSERT INTO market_intelligence.brands (brand_key, display_name, category, is_tippos, aliases)
VALUES ('tippos', 'TIPPOS', 'product', true, ARRAY['tippos', 'Tippos', 'TIPPOS'])
ON CONFLICT (brand_key) DO UPDATE SET display_name = EXCLUDED.display_name, is_tippos = true, updated_at = now();

INSERT INTO market_intelligence.score_definitions (score_key, version, description, formula)
VALUES (
  'language_market_opportunity', 1,
  'Prioritizes product languages using measured demand, growth, business relevance, AI visibility gap, competition, coverage and localization effort. Coverage below 35 forces validation rather than implementation.',
  '{"demand":0.30,"growth":0.15,"business_relevance":0.20,"ai_visibility_gap":0.10,"competition_opportunity":0.10,"data_coverage":0.10,"localization_effort":0.05,"minimum_coverage_for_implementation":35,"implementation_threshold":70}'::jsonb
)
ON CONFLICT (score_key, version) DO UPDATE SET description = EXCLUDED.description, formula = EXCLUDED.formula;

-- 100 discovery seeds across ten languages. They are hypotheses, not volume data.
WITH seeds(language_code, original_text, intent, funnel_stage, use_case, relevance) AS (
  VALUES
    ('en','digital tipping','commercial','awareness','digital-tipping',95),
    ('en','cashless tipping app','commercial','consideration','digital-tipping',95),
    ('en','how to tip without cash','informational','awareness','digital-tipping',90),
    ('en','how much to tip hotel housekeeping','informational','awareness','hospitality',90),
    ('en','QR code tipping','commercial','consideration','digital-tipping',95),
    ('en','hotel tipping platform','commercial','conversion','business-solutions',100),
    ('en','tip a valet without cash','transactional','conversion','transport',90),
    ('en','digital tips for restaurant staff','commercial','consideration','restaurants',90),
    ('en','receive tips online','transactional','conversion','recipient-tools',95),
    ('en','spa tipping etiquette','informational','awareness','wellness',75),
    ('es','propinas digitales','commercial','awareness','digital-tipping',95),
    ('es','aplicación de propinas sin efectivo','commercial','consideration','digital-tipping',95),
    ('es','cómo dejar propina sin efectivo','informational','awareness','digital-tipping',90),
    ('es','cuánta propina dejar en un hotel','informational','awareness','hospitality',90),
    ('es','propinas con código QR','commercial','consideration','digital-tipping',95),
    ('es','plataforma de propinas para hoteles','commercial','conversion','business-solutions',100),
    ('es','propina para aparcacoches sin efectivo','transactional','conversion','transport',90),
    ('es','propinas digitales para camareros','commercial','consideration','restaurants',90),
    ('es','recibir propinas por internet','transactional','conversion','recipient-tools',95),
    ('es','cuánta propina dejar en un spa','informational','awareness','wellness',75),
    ('fr','pourboire numérique','commercial','awareness','digital-tipping',95),
    ('fr','application de pourboire sans espèces','commercial','consideration','digital-tipping',95),
    ('fr','comment donner un pourboire sans espèces','informational','awareness','digital-tipping',90),
    ('fr','combien donner au personnel de ménage hôtel','informational','awareness','hospitality',90),
    ('fr','pourboire par code QR','commercial','consideration','digital-tipping',95),
    ('fr','plateforme de pourboires pour hôtels','commercial','conversion','business-solutions',100),
    ('fr','pourboire voiturier sans espèces','transactional','conversion','transport',90),
    ('fr','pourboires numériques pour serveurs','commercial','consideration','restaurants',90),
    ('fr','recevoir des pourboires en ligne','transactional','conversion','recipient-tools',95),
    ('fr','pourboire dans un spa','informational','awareness','wellness',75),
    ('de','digitales Trinkgeld','commercial','awareness','digital-tipping',95),
    ('de','bargeldlose Trinkgeld App','commercial','consideration','digital-tipping',95),
    ('de','Trinkgeld geben ohne Bargeld','informational','awareness','digital-tipping',90),
    ('de','Trinkgeld für Zimmerreinigung im Hotel','informational','awareness','hospitality',90),
    ('de','Trinkgeld per QR Code','commercial','consideration','digital-tipping',95),
    ('de','Trinkgeldplattform für Hotels','commercial','conversion','business-solutions',100),
    ('de','Trinkgeld für Parkservice ohne Bargeld','transactional','conversion','transport',90),
    ('de','digitales Trinkgeld für Kellner','commercial','consideration','restaurants',90),
    ('de','Trinkgeld online erhalten','transactional','conversion','recipient-tools',95),
    ('de','Trinkgeld im Spa','informational','awareness','wellness',75),
    ('pt','gorjeta digital','commercial','awareness','digital-tipping',95),
    ('pt','aplicativo de gorjeta sem dinheiro','commercial','consideration','digital-tipping',95),
    ('pt','como dar gorjeta sem dinheiro','informational','awareness','digital-tipping',90),
    ('pt','quanto dar de gorjeta no hotel','informational','awareness','hospitality',90),
    ('pt','gorjeta por código QR','commercial','consideration','digital-tipping',95),
    ('pt','plataforma de gorjetas para hotéis','commercial','conversion','business-solutions',100),
    ('pt','gorjeta para manobrista sem dinheiro','transactional','conversion','transport',90),
    ('pt','gorjetas digitais para garçons','commercial','consideration','restaurants',90),
    ('pt','receber gorjetas online','transactional','conversion','recipient-tools',95),
    ('pt','gorjeta em spa','informational','awareness','wellness',75),
    ('it','mancia digitale','commercial','awareness','digital-tipping',95),
    ('it','app per mance senza contanti','commercial','consideration','digital-tipping',95),
    ('it','come lasciare la mancia senza contanti','informational','awareness','digital-tipping',90),
    ('it','quanto lasciare di mancia in hotel','informational','awareness','hospitality',90),
    ('it','mancia con codice QR','commercial','consideration','digital-tipping',95),
    ('it','piattaforma di mance per hotel','commercial','conversion','business-solutions',100),
    ('it','mancia al parcheggiatore senza contanti','transactional','conversion','transport',90),
    ('it','mance digitali per camerieri','commercial','consideration','restaurants',90),
    ('it','ricevere mance online','transactional','conversion','recipient-tools',95),
    ('it','mancia alla spa','informational','awareness','wellness',75),
    ('nl','digitale fooi','commercial','awareness','digital-tipping',95),
    ('nl','fooi app zonder contant geld','commercial','consideration','digital-tipping',95),
    ('nl','fooi geven zonder contant geld','informational','awareness','digital-tipping',90),
    ('nl','hoeveel fooi voor hotel schoonmaak','informational','awareness','hospitality',90),
    ('nl','fooi via QR code','commercial','consideration','digital-tipping',95),
    ('nl','fooiplatform voor hotels','commercial','conversion','business-solutions',100),
    ('nl','fooi voor valet zonder contant geld','transactional','conversion','transport',90),
    ('nl','digitale fooien voor bediening','commercial','consideration','restaurants',90),
    ('nl','online fooien ontvangen','transactional','conversion','recipient-tools',95),
    ('nl','fooi in een spa','informational','awareness','wellness',75),
    ('ar','بقشيش رقمي','commercial','awareness','digital-tipping',95),
    ('ar','تطبيق بقشيش بدون نقد','commercial','consideration','digital-tipping',95),
    ('ar','كيف أعطي بقشيش بدون نقد','informational','awareness','digital-tipping',90),
    ('ar','كم بقشيش تنظيف الفندق','informational','awareness','hospitality',90),
    ('ar','بقشيش عبر رمز QR','commercial','consideration','digital-tipping',95),
    ('ar','منصة بقشيش للفنادق','commercial','conversion','business-solutions',100),
    ('ar','بقشيش لخدمة صف السيارات بدون نقد','transactional','conversion','transport',90),
    ('ar','بقشيش رقمي للنادل','commercial','consideration','restaurants',90),
    ('ar','استلام البقشيش عبر الإنترنت','transactional','conversion','recipient-tools',95),
    ('ar','بقشيش في السبا','informational','awareness','wellness',75),
    ('he','טיפ דיגיטלי','commercial','awareness','digital-tipping',95),
    ('he','אפליקציה לטיפ בלי מזומן','commercial','consideration','digital-tipping',95),
    ('he','איך משאירים טיפ בלי מזומן','informational','awareness','digital-tipping',90),
    ('he','כמה טיפ משאירים לחדרנית במלון','informational','awareness','hospitality',90),
    ('he','טיפ באמצעות קוד QR','commercial','consideration','digital-tipping',95),
    ('he','מערכת טיפים לבתי מלון','commercial','conversion','business-solutions',100),
    ('he','טיפ לשירות חניה בלי מזומן','transactional','conversion','transport',90),
    ('he','טיפים דיגיטליים למלצרים','commercial','consideration','restaurants',90),
    ('he','קבלת טיפים באינטרנט','transactional','conversion','recipient-tools',95),
    ('he','כמה טיפ משאירים בספא','informational','awareness','wellness',75),
    ('ja','デジタルチップ','commercial','awareness','digital-tipping',95),
    ('ja','現金不要のチップアプリ','commercial','consideration','digital-tipping',95),
    ('ja','現金なしでチップを渡す方法','informational','awareness','digital-tipping',90),
    ('ja','ホテル清掃員へのチップはいくら','informational','awareness','hospitality',90),
    ('ja','QRコードでチップ','commercial','consideration','digital-tipping',95),
    ('ja','ホテル向けチップシステム','commercial','conversion','business-solutions',100),
    ('ja','バレーサービスに現金なしでチップ','transactional','conversion','transport',90),
    ('ja','レストランスタッフへのデジタルチップ','commercial','consideration','restaurants',90),
    ('ja','オンラインでチップを受け取る','transactional','conversion','recipient-tools',95),
    ('ja','スパでのチップ','informational','awareness','wellness',75)
)
INSERT INTO market_intelligence.keywords
  (original_text, normalized_text, language_code, intent, funnel_stage, use_case, business_relevance)
SELECT original_text, market_intelligence.normalize_text(original_text), language_code,
  intent::market_intelligence.search_intent, funnel_stage, use_case, relevance
FROM seeds
ON CONFLICT (normalized_text, language_code, (coalesce(country_code, '*'))) DO UPDATE SET
  intent = EXCLUDED.intent,
  funnel_stage = EXCLUDED.funnel_stage,
  use_case = EXCLUDED.use_case,
  business_relevance = EXCLUDED.business_relevance,
  updated_at = now();

INSERT INTO market_intelligence.ai_prompt_sets (set_key, display_name, description, schedule)
VALUES ('language-discovery-v1', 'Language market discovery', 'Representative prompts used to compare TIPPOS visibility and tipping demand by language.', 'weekly')
ON CONFLICT (set_key) DO UPDATE SET description = EXCLUDED.description, schedule = EXCLUDED.schedule, updated_at = now();

-- Five prompts in eight languages = 40 initial visibility checks.
WITH prompt_seed(language_code, suffix, prompt_text, persona, funnel_stage) AS (
  VALUES
    ('en','cashless','What is the best way to tip a service worker when I have no cash?','traveler','awareness'),
    ('en','hotel','Which digital tipping solutions work for hotel housekeeping?','hotel_guest','consideration'),
    ('en','business','Recommend a digital tipping platform for a hotel.','hotel_operator','conversion'),
    ('en','recipient','How can a service worker receive tips by QR code?','service_worker','consideration'),
    ('en','brand','What is TIPPOS and how does it compare with other tipping options?','buyer','consideration'),
    ('es','cashless','¿Cuál es la mejor forma de dar propina a un trabajador si no tengo efectivo?','traveler','awareness'),
    ('es','hotel','¿Qué soluciones de propinas digitales sirven para el personal de limpieza de hoteles?','hotel_guest','consideration'),
    ('es','business','Recomienda una plataforma de propinas digitales para un hotel.','hotel_operator','conversion'),
    ('es','recipient','¿Cómo puede un trabajador recibir propinas mediante un código QR?','service_worker','consideration'),
    ('es','brand','¿Qué es TIPPOS y cómo se compara con otras opciones de propinas?','buyer','consideration'),
    ('fr','cashless','Quelle est la meilleure façon de donner un pourboire sans espèces?','traveler','awareness'),
    ('fr','hotel','Quelles solutions de pourboire numérique conviennent au personnel de ménage hôtelier?','hotel_guest','consideration'),
    ('fr','business','Recommande une plateforme de pourboires numériques pour un hôtel.','hotel_operator','conversion'),
    ('fr','recipient','Comment un employé peut-il recevoir des pourboires par code QR?','service_worker','consideration'),
    ('fr','brand','Qu’est-ce que TIPPOS et comment se compare-t-il aux autres solutions?','buyer','consideration'),
    ('de','cashless','Wie kann ich einem Service-Mitarbeiter ohne Bargeld Trinkgeld geben?','traveler','awareness'),
    ('de','hotel','Welche digitalen Trinkgeldlösungen eignen sich für Hotelreinigungskräfte?','hotel_guest','consideration'),
    ('de','business','Empfiehl eine digitale Trinkgeldplattform für ein Hotel.','hotel_operator','conversion'),
    ('de','recipient','Wie können Servicekräfte Trinkgeld per QR-Code erhalten?','service_worker','consideration'),
    ('de','brand','Was ist TIPPOS und wie unterscheidet es sich von anderen Trinkgeldlösungen?','buyer','consideration'),
    ('pt','cashless','Qual é a melhor forma de dar gorjeta sem dinheiro?','traveler','awareness'),
    ('pt','hotel','Quais soluções de gorjeta digital funcionam para camareiras de hotel?','hotel_guest','consideration'),
    ('pt','business','Recomende uma plataforma de gorjetas digitais para um hotel.','hotel_operator','conversion'),
    ('pt','recipient','Como um trabalhador pode receber gorjetas por código QR?','service_worker','consideration'),
    ('pt','brand','O que é TIPPOS e como se compara a outras opções de gorjeta?','buyer','consideration'),
    ('it','cashless','Qual è il modo migliore per lasciare una mancia senza contanti?','traveler','awareness'),
    ('it','hotel','Quali soluzioni di mancia digitale funzionano per il personale degli hotel?','hotel_guest','consideration'),
    ('it','business','Consiglia una piattaforma di mance digitali per un hotel.','hotel_operator','conversion'),
    ('it','recipient','Come può un lavoratore ricevere mance tramite codice QR?','service_worker','consideration'),
    ('it','brand','Che cos’è TIPPOS e come si confronta con altre soluzioni per le mance?','buyer','consideration'),
    ('ar','cashless','ما أفضل طريقة لإعطاء بقشيش لعامل خدمة بدون نقد؟','traveler','awareness'),
    ('ar','hotel','ما حلول البقشيش الرقمي المناسبة لعمال تنظيف الفنادق؟','hotel_guest','consideration'),
    ('ar','business','اقترح منصة بقشيش رقمية لفندق.','hotel_operator','conversion'),
    ('ar','recipient','كيف يمكن لعامل خدمة استلام بقشيش عبر رمز QR؟','service_worker','consideration'),
    ('ar','brand','ما هي TIPPOS وكيف تقارن بخيارات البقشيش الأخرى؟','buyer','consideration'),
    ('he','cashless','מה הדרך הטובה ביותר לתת טיפ לעובד שירות כשאין לי מזומן?','traveler','awareness'),
    ('he','hotel','אילו פתרונות לטיפים דיגיטליים מתאימים לעובדי ניקיון במלון?','hotel_guest','consideration'),
    ('he','business','המלץ על פלטפורמת טיפים דיגיטליים לבית מלון.','hotel_operator','conversion'),
    ('he','recipient','איך עובד שירות יכול לקבל טיפ באמצעות קוד QR?','service_worker','consideration'),
    ('he','brand','מה זה TIPPOS ואיך הוא משתווה לפתרונות טיפים אחרים?','buyer','consideration')
), prompt_set AS (
  SELECT id FROM market_intelligence.ai_prompt_sets WHERE set_key = 'language-discovery-v1'
)
INSERT INTO market_intelligence.ai_prompts
  (prompt_set_id, prompt_key, version, prompt_text, language_code, persona, funnel_stage, use_case)
SELECT ps.id, 'language-discovery-v1-' || p.language_code || '-' || p.suffix, 1,
  p.prompt_text, p.language_code, p.persona, p.funnel_stage, 'language-market-discovery'
FROM prompt_seed p CROSS JOIN prompt_set ps
ON CONFLICT (prompt_key) DO UPDATE SET
  prompt_text = EXCLUDED.prompt_text,
  persona = EXCLUDED.persona,
  funnel_stage = EXCLUDED.funnel_stage,
  active = true,
  updated_at = now();
