/* ===============================================================================
   Relative Path : precheck/医疗服务项目执行积分_医技护执行比例未配置.sql

   规则用途   : 「执行前校验」规则 SQL —— 用于核算执行**前**拦截，不再作为事后报表
   归属核算项 : 一次分配/医疗服务项目执行积分.sql
                （该脚本 LEFT JOIN DIM_DEPT_ITEM_EXEC_RATIO，落空时四条执行比例按 0 处理
                 → 该月这部分工作量不计分，属实质性漏算）
   规则名称   : 医技护执行比例未配置
   建议级别   : BLOCK（比例缺失直接导致金额算错，应阻断执行）
   建议超时   : 30 秒
   建议行数   : 200（最多展示 200 行，超出提示"仅显示前 200 行，请导出查看全部"）

   参数占位符 : '{year}'  核算年（如 '2026'）
                '{month}' 核算月（如 '11'）
                时间口径与计分脚本一致：按 [缴费时间] 落在该自然月

   判定规则   : **返回行数 > 0 即命中**（有行=有问题，0 行=通过）
   输出列     : 全部为业务中文列，页面/导出直接展示，不再使用 object_code 之类技术列
                配置键区：HIS科室编码 / HIS科室名称 / 项目代码 / 项目名称 / HIS类别名称
                          （顺序与 DIM_DEPT_ITEM_EXEC_RATIO 列序一致，便于照单维护）
                缺口区  ：缺口类型 / 说明
                参考区  ：发生笔数 / 金额 / 金额占比%
                期间区  ：核算年份 / 核算月份（放最后，避免干扰阅读）

   只读声明   : 纯 SELECT，无任何写操作；全链路 WITH (NOLOCK)
   生成日期   : 2026-11-23
   来源       : 由 analyses/月度未配置医技护执行比例明细.sql 改造
                （报表为事后排查，本规则改为执行前拦截；口径与列完全沿用）
   =============================================================================== */

DECLARE @year  INT = CAST('{year}'  AS INT);
DECLARE @month INT = CAST('{month}' AS INT);

DECLARE @start_time DATETIME = DATEFROMPARTS(@year, @month, 1);
DECLARE @end_time   DATETIME = DATEADD(MONTH, 1, @start_time);

WITH fact AS (
    SELECT
        b.[HIS_DEPT_CODE]                                   AS HIS_DEPT_CODE,
        src.[执行科室]                                       AS HIS_DEPT_NAME,
        src.[项目代码]                                       AS ITEM_CODE,
        src.[项目名称]                                       AS ITEM_NAME,
        src.[项目大类]                                       AS HIS_CAT_NAME,
        COUNT(1)                                            AS RECORD_COUNT,
        CAST(SUM(CAST(src.[金额] AS DECIMAL(18,8))) AS DECIMAL(18,8)) AS TOTAL_AMOUNT
    FROM dbo.[PF临时医疗服务项目26A] AS src WITH (NOLOCK)
    INNER JOIN (
        SELECT b.[id] AS DEPT_ID, b.[编码] AS HIS_DEPT_CODE
        FROM dbo.[sjjk_bmb_2025_06_01] AS b WITH (NOLOCK)
    ) AS b
        ON src.[执行科室代码] = b.[DEPT_ID]
    WHERE 1 = 1
      AND src.[缴费时间] >= @start_time
      AND src.[缴费时间] <  @end_time
      AND src.[执行科室代码] IS NOT NULL
      AND src.[项目代码] IS NOT NULL
      -- 非核算项目大类剔除（与执行积分脚本口径一致）
      AND (
          src.[项目大类] NOT IN (N'西药费', N'中草药费', N'中成药费', N'卫生材料费', N'卫生材料')
          OR src.[项目大类] IS NULL
      )
      -- 院外项目剔除
      AND NOT EXISTS (
          SELECT 1 FROM dbo.[DIM_OUT_HOSP_ITEM] AS o WITH (NOLOCK)
          WHERE o.[ITEM_CODE] = src.[项目代码]
      )
    GROUP BY
        b.[HIS_DEPT_CODE], src.[执行科室], src.[项目代码], src.[项目名称], src.[项目大类]
),
ratio AS (
    SELECT r.[HIS_DEPT_CODE], r.[ITEM_CODE]
    FROM dbo.[DIM_DEPT_ITEM_EXEC_RATIO] AS r WITH (NOLOCK)
    WHERE r.[IS_ENABLED] = 1
),
miss AS (
    SELECT
        f.*,
        CAST(SUM(f.TOTAL_AMOUNT) OVER () AS DECIMAL(18,8)) AS ALL_AMOUNT,
        CAST(100.0 * f.TOTAL_AMOUNT / NULLIF(SUM(f.TOTAL_AMOUNT) OVER (), 0) AS DECIMAL(18,2)) AS AMOUNT_PCT
    FROM fact AS f
    LEFT JOIN ratio AS r
        ON r.[HIS_DEPT_CODE] = f.[HIS_DEPT_CODE]
       AND r.[ITEM_CODE]     = f.[ITEM_CODE]
    WHERE r.[HIS_DEPT_CODE] IS NULL
)
SELECT TOP (200)
    -- 配置键区：与 DIM_DEPT_ITEM_EXEC_RATIO 的列顺序对齐，便于照单维护
    m.[HIS_DEPT_CODE]                        AS [HIS科室编码],
    m.[HIS_DEPT_NAME]                        AS [HIS科室名称],
    m.[ITEM_CODE]                            AS [项目代码],
    m.[ITEM_NAME]                            AS [项目名称],
    m.[HIS_CAT_NAME]                         AS [HIS类别名称],
    -- 缺口说明区：告诉维护人“缺什么、为什么必须补”
    N'未配置执行比例'                          AS [缺口类型],
    N'该科室+项目在DIM_DEPT_ITEM_EXEC_RATIO中无生效配置，执行积分按0计' AS [说明],
    -- 业务参考区：用于排优先级（先补金额大的）
    m.[RECORD_COUNT]                         AS [发生笔数],
    m.[TOTAL_AMOUNT]                         AS [金额],
    m.[AMOUNT_PCT]                           AS [金额占比%],
    -- 期间放最后，避免干扰前两区阅读
    CAST(@year  AS VARCHAR(10))              AS [核算年份],
    CAST(@month AS VARCHAR(10))              AS [核算月份]
FROM miss AS m
ORDER BY
    m.[TOTAL_AMOUNT] DESC,
    m.[HIS_DEPT_CODE] ASC,
    m.[ITEM_CODE] ASC;
