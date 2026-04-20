{{ config(materialized='view') }}

SELECT
    locale_code,
    locale_name,
    language,
    country
FROM {{ ref('locales') }}
