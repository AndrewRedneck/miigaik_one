-- ============================================================
-- Автоматизация измерения производительности
-- ============================================================
-- Исследование:
-- «Сравнительный анализ архитектур хранения
-- пространственно-временных данных в геоинформационных
-- системах мониторинга посевных площадей»
--
-- PostgreSQL 18
-- PostGIS 3.6.2
--
-- Для итогового эксперимента:
--
--     shared_buffers = 1 GB
--
-- Для каждой комбинации:
--
--     аналитический запрос × модель хранения
--
-- выполнялись:
--
--     5 cold-cache измерений;
--     2 прогревающих выполнения;
--     10 warm-cache измерений.
--
-- Основная статистика сравнения:
--
--     медиана Execution Time.
--
-- Термины cold/warm относятся только к PostgreSQL
-- shared buffer cache.
--
-- Кэш файловой системы Windows принудительно
-- не очищался.
-- ============================================================


-- ============================================================
-- 1. Расширение pg_buffercache
-- ============================================================
--
-- Для функции pg_buffercache_evict_all() требуется
-- установленное расширение pg_buffercache.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_buffercache;


-- ============================================================
-- 2. Таблица результатов
-- ============================================================

CREATE TABLE IF NOT EXISTS public.benchmark_results
(
    id bigint GENERATED ALWAYS AS IDENTITY
       PRIMARY KEY,

    query_code varchar(10) NOT NULL,
    model_code varchar(10) NOT NULL,
    cache_mode varchar(10) NOT NULL,
    run_no integer NOT NULL,

    execution_time_ms double precision NOT NULL,

    shared_hit bigint,
    shared_read bigint,

    measured_at timestamptz NOT NULL
        DEFAULT clock_timestamp()
);


-- ============================================================
-- 3. Выполнение одного измерения
-- ============================================================
--
-- Функция принимает текст аналитического SELECT-запроса.
--
-- Запрос автоматически оборачивается в:
--
--     EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
--
-- Из JSON-плана извлекаются:
--
--     Execution Time;
--     Shared Hit Blocks;
--     Shared Read Blocks.
--
-- Время возвращается в миллисекундах.
-- ============================================================

CREATE OR REPLACE FUNCTION public.benchmark_single_run(
    p_query text
)
RETURNS TABLE
(
    execution_time_ms double precision,
    shared_hit bigint,
    shared_read bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan json;
BEGIN

    EXECUTE
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '
        || p_query
    INTO v_plan;


    execution_time_ms :=
        (v_plan -> 0 ->> 'Execution Time')::double precision;


    shared_hit :=
        COALESCE(
            (
                v_plan
                -> 0
                -> 'Plan'
                ->> 'Shared Hit Blocks'
            )::bigint,
            0
        );


    shared_read :=
        COALESCE(
            (
                v_plan
                -> 0
                -> 'Plan'
                ->> 'Shared Read Blocks'
            )::bigint,
            0
        );


    RETURN NEXT;

END;
$$;


-- ============================================================
-- 4. Полный цикл измерения одного запроса
-- ============================================================
--
-- Параметры:
--
--     p_query_code — код аналитического запроса
--                    (например, Z01);
--
--     p_model_code — код архитектуры
--                    (I, II, III или IV);
--
--     p_query      — текст измеряемого SELECT.
--
--
-- ЭТАП 1. COLD
-- ------------------------------------------------------------
--
-- Выполняется 5 измерений.
--
-- Перед КАЖДЫМ измерением:
--
--     pg_buffercache_evict_all()
--
-- удаляет страницы из PostgreSQL shared buffer cache.
--
--
-- ЭТАП 2. WARM-UP
-- ------------------------------------------------------------
--
-- Выполняются 2 запроса без очистки кэша.
--
-- Их результаты не сохраняются в benchmark_results.
--
--
-- ЭТАП 3. WARM
-- ------------------------------------------------------------
--
-- Выполняются 10 измеряемых запусков без очистки
-- PostgreSQL shared buffer cache.
--
-- Все 10 результатов сохраняются.
-- ============================================================

CREATE OR REPLACE FUNCTION public.run_benchmark(
    p_query_code text,
    p_model_code text,
    p_query text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    i integer;
    r record;
BEGIN

    -- --------------------------------------------------------
    -- Удаление результатов предыдущего запуска
    -- той же комбинации query × model.
    -- --------------------------------------------------------

    DELETE FROM public.benchmark_results

    WHERE query_code = p_query_code
      AND model_code = p_model_code;


    -- ========================================================
    -- COLD-CACHE
    -- ========================================================

    FOR i IN 1..5 LOOP

        PERFORM pg_buffercache_evict_all();


        SELECT *
        INTO r
        FROM public.benchmark_single_run(p_query);


        INSERT INTO public.benchmark_results
        (
            query_code,
            model_code,
            cache_mode,
            run_no,
            execution_time_ms,
            shared_hit,
            shared_read
        )

        VALUES
        (
            p_query_code,
            p_model_code,
            'cold',
            i,
            r.execution_time_ms,
            r.shared_hit,
            r.shared_read
        );

    END LOOP;


    -- ========================================================
    -- WARM-UP
    -- ========================================================
    --
    -- Два запуска выполняются, но не включаются
    -- в статистику.
    -- ========================================================

    FOR i IN 1..2 LOOP

        SELECT *
        INTO r
        FROM public.benchmark_single_run(p_query);

    END LOOP;


    -- ========================================================
    -- WARM-CACHE
    -- ========================================================

    FOR i IN 1..10 LOOP

        SELECT *
        INTO r
        FROM public.benchmark_single_run(p_query);


        INSERT INTO public.benchmark_results
        (
            query_code,
            model_code,
            cache_mode,
            run_no,
            execution_time_ms,
            shared_hit,
            shared_read
        )

        VALUES
        (
            p_query_code,
            p_model_code,
            'warm',
            i,
            r.execution_time_ms,
            r.shared_hit,
            r.shared_read
        );

    END LOOP;

END;
$$;


-- ============================================================
-- 5. Проверка количества измерений
-- ============================================================
--
-- После одного полного запуска для каждой комбинации
-- query × model ожидается:
--
--     cold = 5
--     warm = 10
--
-- Прогревающие запуски в таблицу не записываются.
-- ============================================================

SELECT
    query_code,
    model_code,
    cache_mode,
    COUNT(*) AS measurements

FROM public.benchmark_results

GROUP BY
    query_code,
    model_code,
    cache_mode

ORDER BY
    query_code,
    model_code,
    cache_mode;


-- ============================================================
-- 6. Расчет итоговой статистики
-- ============================================================
--
-- Для каждой комбинации query × model × cache_mode
-- рассчитываются:
--
--     медиана;
--     среднее;
--     минимум;
--     максимум.
--
-- В статье основным показателем для сравнительного анализа
-- является медиана warm-cache.
-- ============================================================

SELECT
    query_code,
    model_code,
    cache_mode,

    percentile_cont(0.5)
        WITHIN GROUP
        (
            ORDER BY execution_time_ms
        ) AS median_ms,

    AVG(execution_time_ms) AS mean_ms,

    MIN(execution_time_ms) AS min_ms,

    MAX(execution_time_ms) AS max_ms

FROM public.benchmark_results

GROUP BY
    query_code,
    model_code,
    cache_mode

ORDER BY
    query_code,
    model_code,
    cache_mode;


-- ============================================================
-- 7. Итоговая таблица warm-cache
-- ============================================================
--
-- Этот запрос формирует основные значения, используемые
-- при сравнении архитектур в статье.
-- ============================================================

SELECT
    query_code,
    model_code,

    percentile_cont(0.5)
        WITHIN GROUP
        (
            ORDER BY execution_time_ms
        ) AS median_warm_ms,

    AVG(execution_time_ms) AS mean_warm_ms,

    MIN(execution_time_ms) AS min_warm_ms,

    MAX(execution_time_ms) AS max_warm_ms

FROM public.benchmark_results

WHERE cache_mode = 'warm'

GROUP BY
    query_code,
    model_code

ORDER BY
    query_code,
    model_code;


-- ============================================================
-- 8. Итоговая таблица cold-cache
-- ============================================================

SELECT
    query_code,
    model_code,

    percentile_cont(0.5)
        WITHIN GROUP
        (
            ORDER BY execution_time_ms
        ) AS median_cold_ms,

    AVG(execution_time_ms) AS mean_cold_ms,

    MIN(execution_time_ms) AS min_cold_ms,

    MAX(execution_time_ms) AS max_cold_ms

FROM public.benchmark_results

WHERE cache_mode = 'cold'

GROUP BY
    query_code,
    model_code

ORDER BY
    query_code,
    model_code;


-- ============================================================
-- 9. Контроль параметра shared_buffers
-- ============================================================
--
-- В итоговом эксперименте ожидается:
--
--     shared_buffers = 1GB
-- ============================================================

SHOW shared_buffers;


-- ============================================================
-- 10. Контроль версий СУБД и PostGIS
-- ============================================================

SELECT version();

SELECT PostGIS_Full_Version();


-- ============================================================
-- Примечания по интерпретации
-- ============================================================
--
-- 1. Cold-cache
--
--    Перед каждым измеряемым cold-запуском очищается
--    PostgreSQL shared buffer cache.
--
--    Это НЕ означает полную очистку всех уровней
--    кэширования операционной системы и накопителя.
--
--
-- 2. Warm-cache
--
--    После cold-серии выполняются два дополнительных
--    прогревающих запуска.
--
--    После них выполняются 10 измеряемых запусков
--    без очистки PostgreSQL shared buffers.
--
--
-- 3. shared_buffers
--
--    Во всех итоговых измерениях использовалось
--    одинаковое значение:
--
--        1 GB.
--
--
-- 4. Предварительная обработка
--
--    Время формирования материализованных представлений
--    MODEL III и многомерной структуры MODEL IV
--    не включается во время выполнения аналитических
--    SELECT-запросов.
--
--    Эти затраты измеряются отдельно.
--
--
-- 5. З-7 и З-8
--
--    Результаты З-7 и З-8 не используются для расчета
--    прямого коэффициента ускорения MODEL III / MODEL IV
--    относительно MODEL I / MODEL II.
--
--    В этих сценариях архитектуры выполняют разные стадии
--    обработки пространственных данных.
-- ============================================================
