-- ============================================================
-- З-4. Агрегация по муниципальным образованиям,
--      культурам и сезонам
-- ============================================================
-- Назначение:
-- определение количества пространственных объектов и
-- суммарной площади посевов в разрезе:
--
--     муниципальное образование × культура × сезон
--
-- Измерения:
--   муниципальное образование;
--   культура;
--   время.
--
-- Показатели:
--   количество объектов;
--   площадь, га.
--
-- Период:
--   2024–2026 гг.
--
-- Для моделей I и II территориальная принадлежность
-- определяется непосредственно при выполнении запроса.
--
-- Для моделей III и IV пространственное сопоставление
-- выполнено предварительно при формировании соответствующих
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
    municipality,
    crop,
    season,
    COUNT(*) AS field_count,
    SUM(area_ha) AS area_ha

FROM assigned

GROUP BY
    municipality,
    crop,
    season;


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
    municipality,
    crop,
    season,
    COUNT(*) AS field_count,
    SUM(area_ha) AS area_ha

FROM assigned

GROUP BY
    municipality,
    crop,
    season;


-- ============================================================
-- MODEL III
-- Материализованные представления
-- ============================================================

SELECT
    municipality,
    crop,
    season,
    field_count,
    area_ha

FROM public.mv_municipality_crop_season

WHERE season BETWEEN 2024 AND 2026;


-- ============================================================
-- MODEL IV
-- Многомерная модель типа «звезда»
-- ============================================================

SELECT
    dm.municipality_name AS municipality,
    dc.crop_code AS crop,
    dt.season,

    SUM(f.field_count) AS field_count,
    SUM(f.area_ha) AS area_ha

FROM olap.fact_sowing AS f

JOIN olap.dim_time AS dt
  ON dt.time_id = f.time_id

JOIN olap.dim_crop AS dc
  ON dc.crop_id = f.crop_id

JOIN olap.dim_municipality AS dm
  ON dm.municipality_id = f.municipality_id

WHERE dt.season BETWEEN 2024 AND 2026

GROUP BY
    dm.municipality_name,
    dc.crop_code,
    dt.season;


-- ============================================================
-- Проверка семантической эквивалентности
-- ============================================================
--
-- Результаты четырех реализаций З-4 сопоставлялись
-- по комбинации:
--
--     municipality × crop × season
--
-- за 2024–2026 гг.
--
-- Перед измерением производительности было подтверждено:
--
--   - совпадение состава групп;
--   - совпадение field_count;
--   - совпадение площади с учетом погрешности вычислений
--     double precision.
--
-- Модель III хранит результат именно на уровне
-- municipality × crop × season, поэтому дополнительная
-- агрегация для выполнения З-4 не требуется.
--
-- Модель IV имеет более детальную гранулярность таблицы
-- фактов:
--
--     season × crop × municipality × land_user
--
-- поэтому при выполнении З-4 показатели суммируются
-- по землепользователям.
-- ============================================================


-- ============================================================
-- Особенность интерпретации производительности
-- ============================================================
--
-- Для моделей I и II З-4 непосредственно включает:
--
--     ST_Intersects;
--     ST_Intersection;
--     ST_Area;
--     ST_Transform;
--     выбор максимального overlap_ratio;
--     проверку условия overlap_ratio > 0.8;
--     последующую агрегацию.
--
-- Для моделей III и IV пространственная операция перенесена
-- на этап предварительного формирования структуры.
--
-- Поэтому сравнение времени выполнения аналитического
-- SELECT не является сравнением полной стоимости получения
-- результата «с нуля».
--
-- Время первоначального формирования и обновления
-- производных структур учитывается отдельно.
-- ============================================================


-- ============================================================
-- Измерение производительности
-- ============================================================
--
-- Используемый протокол:
--
--   cold:
--       5 измерений;
--       перед каждым измерением очищался PostgreSQL
--       shared buffer cache;
--
--   warm:
--       2 прогревающих запуска;
--       10 измеряемых запусков.
--
-- Основная статистика:
--       медиана Execution Time.
--
-- Медианы warm-cache:
--
--     Model I:     26 949.207 ms
--     Model II:    25 805.589 ms
--     Model III:        0.183 ms
--     Model IV:        19.053 ms
--
-- Для моделей III и IV указанные значения характеризуют
-- только выполнение запроса к предварительно сформированным
-- аналитическим структурам.
--
-- Стоимость предварительной обработки в эти значения
-- не включена.
--
-- Полная процедура измерения:
--
--     benchmark/benchmark_runner.sql
-- ============================================================
