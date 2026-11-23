/* ===============================================================================
   Relative Path : precheck/门诊诊察类项目执行积分_接诊日期未配置工作日历.sql

   规则用途   : 「核算项校验规则」——执行前拦截“门诊接诊日期在工作日历中无配置”的情况
   归属核算项 : 一次分配/门诊诊察类项目执行积分_非小儿科.sql（以及 _小儿科.sql，共用同一日历表）
                计算脚本 LEFT JOIN dbo.[DIM_WORK_CALENDAR] ON CAST([接诊时间] AS DATE) = [CALC_DATE]，
                日历缺失时 [日期类型] 为空，按日期类型维度的核算口径会失真。
   规则名称   : 接诊日期未配置工作日历
   建议级别   : BLOCK（日期类型缺失会直接影响维度口径，属实质错误）
   建议超时   : 60 秒
   建议行数   : 200

   参数占位符 : '{year}' / '{month}'（按 [接诊时间] 落在该自然月）
   判定规则   : **返回行数 > 0 即命中**

   输出列:
     日期          缺失的工作日历日期（YYYY-MM-DD）
     门诊记录数    该日期在门诊来源、1043 类项目下的记录条数（按条数排序，先补大日期）
     排查与补配指引 具体去补哪张表、哪个字段

   口径说明   :
     - 与计算脚本同源：门诊诊察类（ITEM_CAT_CODE='1043'）、[来源]=N'门诊'、[接诊时间] 当月
     - 不区分小儿科/非小儿科（日历与科室无关，一次检查覆盖两个脚本）
     - 日历表：dbo.[DIM_WORK_CALENDAR].[CALC_DATE]

   只读声明   : 纯 SELECT，无写操作；全链路 WITH (NOLOCK)
   生成日期   : 2026-11-23
   =============================================================================== */

DECLARE @year  INT = CAST('{year}'  AS INT);
DECLARE @month INT = CAST('{month}' AS INT);

DECLARE @start_time DATETIME = DATEFROMPARTS(@year, @month, 1);
DECLARE @end_time   DATETIME = DATEADD(SECOND, -1, DATEADD(MONTH, 1, @start_time));

WITH cte_rvu AS (
    -- 门诊诊察类（1043）收费项目
    SELECT DISTINCT
        v0.[PROJ_CODE]      AS PROJ_CODE
    FROM dbo.[DIM_PRF_ITEM_RVU_VERSION] AS v0 WITH (NOLOCK)
    WHERE v0.[PROJ_CODE] IS NOT NULL
      AND v0.[ITEM_CAT_CODE] = '1043'
),
cte_dates AS (
    -- 当月实际发生的门诊接诊日期
    SELECT
        CAST(f.[接诊时间] AS DATE) AS CALC_DATE,
        COUNT(1)                   AS RECORD_CNT
    FROM dbo.[PF临时医疗服务项目26A] AS f WITH (NOLOCK)
    INNER JOIN cte_rvu AS v
        ON f.[项目代码] = v.[PROJ_CODE]
    WHERE 1 = 1
      AND f.[接诊时间] >= @start_time
      AND f.[接诊时间] <= @end_time
      AND f.[来源] = N'门诊'
      AND f.[接诊时间] IS NOT NULL
    GROUP BY CAST(f.[接诊时间] AS DATE)
)
SELECT TOP (200)
    CONVERT(VARCHAR(10), d.[CALC_DATE], 120)                          AS [日期],
    CAST(d.[RECORD_CNT] AS DECIMAL(18,8))                             AS [门诊记录数],
    N'工作日历表(DIM_WORK_CALENDAR)缺少该日期配置 → 请在表中按 CALC_DATE 补录（含日期类型/是否工作日）' AS [排查与补配指引]
FROM cte_dates AS d
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.[DIM_WORK_CALENDAR] AS c WITH (NOLOCK)
    WHERE CAST(c.[CALC_DATE] AS DATE) = d.[CALC_DATE]
)
ORDER BY
    d.[RECORD_CNT] DESC,
    d.[CALC_DATE] ASC;
