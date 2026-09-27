-- ============================================================
-- Модель III. Материализованные представления
-- ============================================================
-- Исследование:
-- «Сравнительный анализ архитектур хранения
-- пространственно-временных данных в геоинформационных
-- системах мониторинга посевных площадей»
--
-- Модель III включает исходную таблицу и три
-- специализированных материализованных представления:
--
--   1. культура × сезон;
--   2. муниципальное образование × культура × сезон;
--   3. землепользователь × культура × сезон.
--
-- Материализованные представления формируются исключительно
-- на основе собственной исходной таблицы модели III:
--
--     public.v3_sowing_mv_base
--
-- и не используют таблицы или индексы других исследуемых
-- моделей.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Исходная таблица модели III
-- ------------------------------------------------------------

CREATE TABLE public.v3_sowing_mv_base
(
    id          integer,
    geom        geometry,
    id_sub      varchar,
    rgis_code   varchar,
    onfarm_cod  varchar,
    season      integer,
    crop        integer,
    okpd2       varchar,
    crop_vid    varchar,
    comment     varchar,
    land_inn    varchar,
    land_kpp    varchar,
    date_sow    date,
    batch_num   varchar,
    crop_num    varchar,
    seeds_val   varchar,
    purpose     integer,
    gos_crop    integer,
    plan_use    integer,
    d_sow_end   date,
    products    integer
);

ANALYZE public.v3_sowing_mv_base;


-- ============================================================
-- 2. Материализованное представление:
--    культура × сезон
-- ============================================================

CREATE MATERIALIZED VIEW public.mv_crop_season AS
SELECT
    season,
    crop,
    COUNT(*) AS field_count,
    SUM(
        ST_Area(
            ST_Transform(geom, 3857)
        )
    ) / 10000.0 AS area_ha
FROM public.v3_sowing_mv_base
WHERE geom IS NOT NULL
  AND crop IS NOT NULL
GROUP BY
    season,
    crop;


CREATE INDEX idx_mv_crop_season
    ON public.mv_crop_season (season, crop);


ANALYZE public.mv_crop_season;


-- ============================================================
-- 3. Материализованное представление:
--    муниципальное образование × культура × сезон
-- ============================================================
--
-- Для каждого пространственного объекта:
--
-- 1. определяются муниципальные образования, с которыми
--    пересекается его геометрия;
--
-- 2. рассчитывается доля площади объекта, приходящаяся
--    на каждое пересечение:
--
--       площадь пересечения / площадь объекта;
--
-- 3. выбирается муниципальное образование с максимальной
--    долей пересечения;
--
-- 4. если максимальная доля строго больше 0.8, объект
--    относится к выбранному муниципальному образованию;
--
-- 5. в остальных случаях используется категория
--    «Не определено».
--
-- В PARTITION BY используется комбинация season, id,
-- поскольку идентификаторы объектов могут повторяться
-- между различными сезонами.
-- ============================================================

CREATE MATERIALIZED VIEW public.mv_municipality_crop_season AS

WITH candidates AS
(
    SELECT
        f.id,
        f.season,
        f.crop,

        ST_Area(
            ST_Transform(f.geom, 3857)
        ) / 10000.0 AS area_ha,

        m."m.name" AS municipality,

        ST_Area(
            ST_Transform(
                ST_Intersection(f.geom, m.geom),
                3857
            )
        )
        /
        NULLIF(
            ST_Area(
                ST_Transform(f.geom, 3857)
            ),
            0
        ) AS overlap_ratio

    FROM public.v3_sowing_mv_base AS f

    JOIN public.municipalities AS m
      ON ST_Intersects(f.geom, m.geom)

    WHERE f.geom IS NOT NULL
      AND f.crop IS NOT NULL
),

best_match AS
(
    SELECT
        *,
        ROW_NUMBER() OVER
        (
            PARTITION BY season, id
            ORDER BY overlap_ratio DESC
        ) AS rn

    FROM candidates
),

assigned AS
(
    SELECT
        season,
        crop,
        area_ha,

        CASE
            WHEN overlap_ratio > 0.8
                THEN municipality
            ELSE 'Не определено'
        END AS municipality

    FROM best_match

    WHERE rn = 1
)

SELECT
    municipality,
    season,
    crop,
    COUNT(*) AS field_count,
    SUM(area_ha) AS area_ha

FROM assigned

GROUP BY
    municipality,
    season,
    crop;


CREATE INDEX idx_mv_municipality_crop_season
    ON public.mv_municipality_crop_season
       (season, crop, municipality);


ANALYZE public.mv_municipality_crop_season;


-- ============================================================
-- 4. Материализованное представление:
--    землепользователь × культура × сезон
-- ============================================================
--
-- Атрибут land_inn используется в эксперименте в качестве
-- идентификатора землепользователя.
--
-- NULL и пустые значения объединяются в категорию
-- «Не определено».
-- ============================================================

CREATE MATERIALIZED VIEW public.mv_land_user_crop_season AS

SELECT
    season,
    crop,

    COALESCE(
        NULLIF(land_inn, ''),
        'Не определено'
    ) AS land_inn,

    COUNT(*) AS field_count,

    SUM(
        ST_Area(
            ST_Transform(geom, 3857)
        )
    ) / 10000.0 AS area_ha

FROM public.v3_sowing_mv_base

WHERE geom IS NOT NULL
  AND crop IS NOT NULL

GROUP BY
    season,
    crop,
    COALESCE(
        NULLIF(land_inn, ''),
        'Не определено'
    );


CREATE INDEX idx_mv_land_user_crop_season
    ON public.mv_land_user_crop_season
       (season, crop, land_inn);


ANALYZE public.mv_land_user_crop_season;


-- ============================================================
-- 5. Обновление материализованных представлений
-- ============================================================
--
-- При полном обновлении производных структур модели III
-- выполняются следующие команды.
-- ============================================================

REFRESH MATERIALIZED VIEW public.mv_crop_season;

REFRESH MATERIALIZED VIEW public.mv_municipality_crop_season;

REFRESH MATERIALIZED VIEW public.mv_land_user_crop_season;


-- После обновления формируется статистика оптимизатора.

ANALYZE public.mv_crop_season;
ANALYZE public.mv_municipality_crop_season;
ANALYZE public.mv_land_user_crop_season;


-- ============================================================
-- 6. Контроль исходных данных
-- ============================================================
-- Для экспериментального набора:
--
-- всего исходных записей: 330 721;
-- записей с geom IS NOT NULL и crop IS NOT NULL: 324 314.
-- ============================================================

SELECT
    COUNT(*) AS source_row_count
FROM public.v3_sowing_mv_base;


SELECT
    COUNT(*) AS valid_row_count
FROM public.v3_sowing_mv_base
WHERE geom IS NOT NULL
  AND crop IS NOT NULL;


-- Контроль по сезонам.

SELECT
    season,
    COUNT(*) AS source_row_count,
    COUNT(*) FILTER
    (
        WHERE geom IS NOT NULL
          AND crop IS NOT NULL
    ) AS valid_row_count

FROM public.v3_sowing_mv_base

GROUP BY season
ORDER BY season;


-- Ожидаемый результат:
--
-- season | source_row_count | valid_row_count
-- -------+------------------+----------------
-- 2024   | 78 748           | 78 727
-- 2025   | 127 302          | 122 151
-- 2026   | 124 671          | 123 436


-- ============================================================
-- 7. Контроль материализованных представлений
-- ============================================================

SELECT
    schemaname,
    matviewname

FROM pg_matviews

WHERE schemaname = 'public'
  AND matviewname IN
  (
      'mv_crop_season',
      'mv_municipality_crop_season',
      'mv_land_user_crop_season'
  )

ORDER BY matviewname;


-- ============================================================
-- 8. Контроль индексов производных структур
-- ============================================================

SELECT
    tablename,
    indexname,
    indexdef

FROM pg_indexes

WHERE schemaname = 'public'
  AND tablename IN
  (
      'mv_crop_season',
      'mv_municipality_crop_season',
      'mv_land_user_crop_season'
  )

ORDER BY
    tablename,
    indexname;
