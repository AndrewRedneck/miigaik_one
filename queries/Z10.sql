-- ============================================================
-- З-10. Drill-down:
--       сезон → муниципальное образование → культура
-- ============================================================
-- Назначение:
-- получение детализированного аналитического результата
-- по иерархии:
--
--     сезон
--         → муниципальное образование
--             → сельскохозяйственная культура
--
-- Измерения:
--     время;
--     муниципальное образование;
--     культура.
--
-- Показатели:
--     количество объектов;
--     суммарная площадь, га.
--
-- Период:
--     2024–2026 гг.
--
-- Для моделей I и II территориальная принадлежность
-- определяется непосредственно при выполнении запроса.
--
-- Для моделей III и IV территориальная принадлежность
-- была рассчитана на этапе предварительного формирования
-- аналитических структур.
-- ============================================================


-- ============================================================
-- MODEL I
-- Базовая реляционная модель
-- ============================================================

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

    FROM public.v1_sowing_relational AS f

    JOIN public.municipalities AS m
      ON ST_Intersects(f.geom, m.geom)

    WHERE f.geom IS NOT NULL
      AND f.crop IS NOT NULL
      AND f.season BETWEEN 2024 AND 2026
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
    season,
    municipality,
    crop,

    COUNT(*) AS field_count,
    SUM(area_ha) AS area_ha

FROM assigned

GROUP BY
    season,
    municipality,
    crop;


-- ============================================================
-- MODEL II
-- Реляционная модель с индексированием
-- ============================================================

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

    FROM public.v2_sowing_indexed AS f

    JOIN public.municipalities AS m
      ON ST_Intersects(f.geom, m.geom)

    WHERE f.geom IS NOT NULL
      AND f.crop IS NOT NULL
      AND f.season BETWEEN 2024 AND 2026
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
    season,
    municipality,
    crop,

    COUNT(*) AS field_count,
    SUM(area_ha) AS area_ha

FROM assigned

GROUP BY
    season,
    municipality,
    crop;


-- ============================================================
-- MODEL III
-- Материализованные представления
-- ============================================================

SELECT
    season,
    municipality,
    crop,
    field_count,
    area_ha

FROM public.mv_municipality_crop_season

WHERE season BETWEEN 2024 AND 2026;


-- ============================================================
-- MODEL IV
-- Многомерная модель типа «звезда»
-- ============================================================

SELECT
    dt.season,
    dm.municipality_name AS municipality,
    dc.crop_code AS crop,

    SUM(f.field_count) AS field_count,
    SUM(f.area_ha) AS area_ha

FROM olap.fact_sowing AS f

JOIN olap.dim_time AS dt
  ON dt.time_id = f.time_id

JOIN olap.dim_municipality AS dm
  ON dm.municipality_id = f.municipality_id

JOIN olap.dim_crop AS dc
  ON dc.crop_id = f.crop_id

WHERE dt.season BETWEEN 2024 AND 2026

GROUP BY
    dt.season,
    dm.municipality_name,
    dc.crop_code;


-- ============================================================
-- Контроль результата
-- ============================================================
--
-- Перед измерением производительности результаты четырех
-- реализаций были сопоставлены по комбинации:
--
--     season × municipality × crop
--
-- Контрольные показатели экспериментального набора:
--
--     количество результирующих групп:
--         3 927
--
--     SUM(field_count):
--         324 314
--
--     SUM(area_ha):
--         ≈ 21 628 760.4787721 га
--
-- Количество объектов совпало для всех четырех моделей.
--
-- Незначительные различия последних десятичных разрядов
-- area_ha обусловлены порядком суммирования значений
-- double precision.
-- ============================================================


-- ============================================================
-- Особенности выполнения
-- ============================================================
--
-- MODEL I / MODEL II
-- ------------------------------------------------------------
-- При выполнении запроса непосредственно осуществляются:
--
--     ST_Intersects;
--     ST_Intersection;
--     ST_Transform;
--     ST_Area;
--     расчет overlap_ratio;
--     выбор муниципального образования;
--     проверка overlap_ratio > 0.8;
--     группировка по season × municipality × crop.
--
--
-- MODEL III
-- ------------------------------------------------------------
-- Материализованное представление
--
--     mv_municipality_crop_season
--
-- уже имеет требуемую гранулярность:
--
--     municipality × season × crop.
--
-- Поэтому дополнительная пространственная обработка
-- и агрегация исходных объектов не требуются.
--
--
-- MODEL IV
-- ------------------------------------------------------------
-- Таблица фактов имеет более детальную гранулярность:
--
--     season × crop × municipality × land_user.
--
-- Поэтому для получения результата З-10 выполняется
-- суммирование по землепользователям.
-- ============================================================


-- ============================================================
-- Семантическая эквивалентность
-- ============================================================
--
-- Для всех архитектур применяется одинаковое правило
-- территориального отнесения:
--
--     overlap_ratio > 0.8
--
-- Если условие не выполняется:
--
--     municipality = 'Не определено'
--
-- Таким образом, перед измерением производительности
-- подтверждена эквивалентность результата по:
--
--     season;
--     municipality;
--     crop;
--     field_count;
--     area_ha
--         (с учетом погрешности double precision).
-- ============================================================


-- ============================================================
-- Интерпретация производительности
-- ============================================================
--
-- Как и в З-3 и З-4, для MODEL I и MODEL II стоимость
-- пространственного территориального сопоставления входит
-- непосредственно во время выполнения З-10.
--
-- Для MODEL III и MODEL IV эта операция перенесена
-- на этап предварительного формирования аналитических
-- структур.
--
-- Поэтому коэффициенты изменения времени выполнения
-- характеризуют аналитическую фазу уже выбранной
-- архитектуры хранения.
--
-- Они не характеризуют полную стоимость получения
-- результата с учетом первоначального построения
-- производных структур.
--
-- Стоимость предварительного формирования MODEL III
-- и MODEL IV учитывается отдельно.
-- ============================================================


-- ============================================================
-- Измерение производительности
-- ============================================================
--
-- Протокол:
--
--   cold:
--       5 измерений;
--       перед каждым запуском очищался PostgreSQL
--       shared buffer cache;
--
--   warm:
--       2 прогревающих запуска;
--       10 измеряемых запусков без очистки кэша.
--
-- Основная статистика:
--       медиана Execution Time.
--
-- Медианы warm-cache:
--
--     Model I:     26 678.870 ms
--     Model II:    24 494.681 ms
--     Model III:        2.718 ms
--     Model IV:        25.989 ms
--
-- Полная процедура измерения приведена в:
--
--     benchmark/benchmark_runner.sql
-- ============================================================
