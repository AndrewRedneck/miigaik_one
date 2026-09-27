-- ============================================================
-- Модель IV. Многомерная модель типа «звезда»
-- ============================================================
-- Исследование:
-- «Сравнительный анализ архитектур хранения
-- пространственно-временных данных в геоинформационных
-- системах мониторинга посевных площадей»
--
-- Модель IV включает:
--
--   1. исходную таблицу public.v4_sowing_source;
--   2. измерение времени;
--   3. измерение сельскохозяйственных культур;
--   4. измерение муниципальных образований;
--   5. измерение землепользователей;
--   6. таблицу фактов.
--
-- Гранулярность таблицы фактов:
--
--   сезон × культура × муниципальное образование
--          × землепользователь
--
-- В таблице фактов сохраняются:
--
--   field_count — количество исходных объектов;
--   area_ha     — суммарная площадь, га.
-- ============================================================


-- ============================================================
-- 1. Исходная таблица модели IV
-- ============================================================

CREATE TABLE public.v4_sowing_source
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

ANALYZE public.v4_sowing_source;


-- ============================================================
-- 2. Схема многомерной модели
-- ============================================================

CREATE SCHEMA IF NOT EXISTS olap;


-- ============================================================
-- 3. Измерение времени
-- ============================================================

CREATE TABLE olap.dim_time
(
    time_id integer PRIMARY KEY,
    season  integer UNIQUE
);


-- ============================================================
-- 4. Измерение сельскохозяйственных культур
-- ============================================================

CREATE TABLE olap.dim_crop
(
    crop_id   integer PRIMARY KEY,
    crop_code integer UNIQUE
);


-- ============================================================
-- 5. Измерение муниципальных образований
-- ============================================================

CREATE TABLE olap.dim_municipality
(
    municipality_id   integer PRIMARY KEY,
    municipality_name varchar UNIQUE
);


-- ============================================================
-- 6. Измерение землепользователей
-- ============================================================

CREATE TABLE olap.dim_land_user
(
    land_user_id integer GENERATED ALWAYS AS IDENTITY
                 PRIMARY KEY,

    land_inn     varchar UNIQUE
);


-- ============================================================
-- 7. Таблица фактов
-- ============================================================

CREATE TABLE olap.fact_sowing
(
    fact_id integer GENERATED ALWAYS AS IDENTITY
            PRIMARY KEY,

    time_id         integer NOT NULL,
    crop_id         integer NOT NULL,
    municipality_id integer NOT NULL,
    land_user_id    integer NOT NULL,

    field_count bigint NOT NULL,
    area_ha     double precision NOT NULL,

    CONSTRAINT fk_fact_time
        FOREIGN KEY (time_id)
        REFERENCES olap.dim_time (time_id),

    CONSTRAINT fk_fact_crop
        FOREIGN KEY (crop_id)
        REFERENCES olap.dim_crop (crop_id),

    CONSTRAINT fk_fact_municipality
        FOREIGN KEY (municipality_id)
        REFERENCES olap.dim_municipality (municipality_id),

    CONSTRAINT fk_fact_land_user
        FOREIGN KEY (land_user_id)
        REFERENCES olap.dim_land_user (land_user_id)
);


-- ============================================================
-- 8. Формирование измерения времени
-- ============================================================
--
-- В измерение включаются только сезоны, представленные
-- среди записей с заданными geom и crop.
-- ============================================================

INSERT INTO olap.dim_time
(
    time_id,
    season
)

SELECT
    ROW_NUMBER() OVER (ORDER BY season)::integer AS time_id,
    season

FROM
(
    SELECT DISTINCT season

    FROM public.v4_sowing_source

    WHERE geom IS NOT NULL
      AND crop IS NOT NULL
      AND season IS NOT NULL
) AS s

ORDER BY season;


-- ============================================================
-- 9. Формирование измерения культур
-- ============================================================

INSERT INTO olap.dim_crop
(
    crop_id,
    crop_code
)

SELECT
    ROW_NUMBER() OVER (ORDER BY crop)::integer AS crop_id,
    crop

FROM
(
    SELECT DISTINCT crop

    FROM public.v4_sowing_source

    WHERE geom IS NOT NULL
      AND crop IS NOT NULL
) AS c

ORDER BY crop;


-- ============================================================
-- 10. Формирование измерения землепользователей
-- ============================================================
--
-- NULL и пустое значение land_inn объединяются
-- в категорию «Не определено».
-- ============================================================

INSERT INTO olap.dim_land_user
(
    land_inn
)

SELECT DISTINCT
    COALESCE(
        NULLIF(land_inn, ''),
        'Не определено'
    )

FROM public.v4_sowing_source

WHERE geom IS NOT NULL
  AND crop IS NOT NULL

ORDER BY 1;


-- ============================================================
-- 11. Пространственное отнесение исходных объектов
-- ============================================================
--
-- Пространственная операция выполняется один раз на этапе
-- формирования многомерной модели.
--
-- Для каждого объекта:
--
--   1. находятся пересекающиеся муниципальные образования;
--   2. определяется доля площади каждого пересечения;
--   3. выбирается максимальная доля;
--   4. при overlap_ratio > 0.8 используется соответствующее
--      муниципальное образование;
--   5. иначе используется категория «Не определено».
--
-- PARTITION BY season, id применяется потому, что id
-- может повторяться в разных сезонах.
-- ============================================================

CREATE TEMP TABLE tmp_assigned AS

WITH candidates AS
(
    SELECT
        f.id,
        f.season,
        f.crop,

        COALESCE(
            NULLIF(f.land_inn, ''),
            'Не определено'
        ) AS land_inn,

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

    FROM public.v4_sowing_source AS f

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
)

SELECT
    season,
    crop,
    land_inn,
    area_ha,

    CASE
        WHEN overlap_ratio > 0.8
            THEN municipality
        ELSE 'Не определено'
    END AS municipality

FROM best_match

WHERE rn = 1;


-- ============================================================
-- 12. Формирование измерения муниципальных образований
-- ============================================================
--
-- Измерение формируется из фактически полученных результатов
-- территориального отнесения. Поэтому оно включает категорию
-- «Не определено», если такие объекты присутствуют.
-- ============================================================

INSERT INTO olap.dim_municipality
(
    municipality_id,
    municipality_name
)

SELECT
    ROW_NUMBER() OVER
    (
        ORDER BY municipality
    )::integer AS municipality_id,

    municipality

FROM
(
    SELECT DISTINCT municipality
    FROM tmp_assigned
) AS m

ORDER BY municipality;


-- ============================================================
-- 13. Формирование таблицы фактов
-- ============================================================

INSERT INTO olap.fact_sowing
(
    time_id,
    crop_id,
    municipality_id,
    land_user_id,
    field_count,
    area_ha
)

SELECT
    dt.time_id,
    dc.crop_id,
    dm.municipality_id,
    dl.land_user_id,

    COUNT(*) AS field_count,
    SUM(a.area_ha) AS area_ha

FROM tmp_assigned AS a

JOIN olap.dim_time AS dt
  ON dt.season = a.season

JOIN olap.dim_crop AS dc
  ON dc.crop_code = a.crop

JOIN olap.dim_municipality AS dm
  ON dm.municipality_name = a.municipality

JOIN olap.dim_land_user AS dl
  ON dl.land_inn = a.land_inn

GROUP BY
    dt.time_id,
    dc.crop_id,
    dm.municipality_id,
    dl.land_user_id;


DROP TABLE tmp_assigned;


-- ============================================================
-- 14. Индексы таблицы фактов
-- ============================================================

CREATE INDEX idx_fact_lu_time
    ON olap.fact_sowing (time_id);

CREATE INDEX idx_fact_lu_crop
    ON olap.fact_sowing (crop_id);

CREATE INDEX idx_fact_lu_municipality
    ON olap.fact_sowing (municipality_id);

CREATE INDEX idx_fact_lu_land_user
    ON olap.fact_sowing (land_user_id);

CREATE INDEX idx_fact_lu_cube
    ON olap.fact_sowing
       (
           time_id,
           crop_id,
           municipality_id,
           land_user_id
       );


-- ============================================================
-- 15. Статистика оптимизатора
-- ============================================================

ANALYZE olap.dim_time;
ANALYZE olap.dim_crop;
ANALYZE olap.dim_municipality;
ANALYZE olap.dim_land_user;
ANALYZE olap.fact_sowing;


-- ============================================================
-- 16. Контроль размеров измерений
-- ============================================================
--
-- Для набора данных, использованного в эксперименте,
-- ожидаемые значения:
--
-- dim_time         = 3
-- dim_crop         = 242
-- dim_municipality = 44
-- dim_land_user    = 6 673
-- ============================================================

SELECT 'dim_time' AS relation,
       COUNT(*) AS row_count
FROM olap.dim_time

UNION ALL

SELECT 'dim_crop',
       COUNT(*)
FROM olap.dim_crop

UNION ALL

SELECT 'dim_municipality',
       COUNT(*)
FROM olap.dim_municipality

UNION ALL

SELECT 'dim_land_user',
       COUNT(*)
FROM olap.dim_land_user;


-- ============================================================
-- 17. Контроль таблицы фактов
-- ============================================================
--
-- Ожидаемое число строк таблицы фактов:
--
-- 47 323
--
-- Сумма field_count:
--
-- 324 314
-- ============================================================

SELECT
    COUNT(*) AS fact_rows,
    SUM(field_count) AS source_fields,
    SUM(area_ha) AS total_area_ha

FROM olap.fact_sowing;


-- ============================================================
-- 18. Контроль таблицы фактов по сезонам
-- ============================================================
--
-- Ожидаемые значения:
--
-- season | fact_rows | source_fields
-- -------+-----------+--------------
-- 2024   | 13 090    | 78 727
-- 2025   | 18 136    | 122 151
-- 2026   | 16 097    | 123 436
-- ============================================================

SELECT
    dt.season,
    COUNT(*) AS fact_rows,
    SUM(f.field_count) AS source_fields,
    SUM(f.area_ha) AS area_ha

FROM olap.fact_sowing AS f

JOIN olap.dim_time AS dt
  ON dt.time_id = f.time_id

GROUP BY dt.season
ORDER BY dt.season;


-- ============================================================
-- 19. Контроль индексов таблицы фактов
-- ============================================================

SELECT
    indexname,
    indexdef

FROM pg_indexes

WHERE schemaname = 'olap'
  AND tablename = 'fact_sowing'

ORDER BY indexname;


-- ============================================================
-- 20. Примечание о предварительной обработке
-- ============================================================
--
-- Время формирования данной структуры учитывалось отдельно
-- от времени выполнения аналитических запросов.
--
-- В итоговом эксперименте медианное время первоначального
-- формирования модели IV составляло:
--
--     22.137 с
--
-- Оно включало:
--
--   - формирование измерений;
--   - пространственное территориальное отнесение;
--   - формирование таблицы фактов;
--   - создание индексов;
--   - ANALYZE.
--
-- Время выполнения аналитических запросов к уже
-- сформированной модели не включает эти затраты.
-- ============================================================
