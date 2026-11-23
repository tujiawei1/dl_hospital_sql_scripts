/* ===============================================================================
   Relative Path : precheck/医疗服务项目开单积分_开单科室未映射核算单元.sql

   规则用途   : 「核算项校验规则」——执行前拦截“开单科室未映射到核算单元”的数据
   归属核算项 : 一次分配/医疗服务项目开单积分.sql
                （映射断链时该部分明细归入 UNIT_CODE='UNKNOWN'，核算单元口径漏计）
   规则名称   : 开单科室未映射核算单元
   建议级别   : BLOCK（归属不明会导致核算单元金额失真，必须先补映射）
   建议超时   : 90 秒
   建议行数   : 200

   参数占位符 : '{year}' / '{month}'（扫描该自然月内 [开单时间] 的明细）
   判定规则   : **返回行数 > 0 即命中**

   断链三类（互斥）:
     ① 字典缺失         [开单科室代码] 在 sjjk_bmb_2025_06_01 中无对应 id
     ② 映射未配置       字典有编码，但 sjjk_DEPT_UNIT_MAPPING_2025_11_27 无职系白名单配置行
     ③ 时间区间不匹配   拉链表有该编码配置，但业务时间不落在任一 [START_DATE, END_DATE]

   输出列（按“业务照着补配置”的动线排序）:
     定位区：HIS科室ID / HIS科室编码 / 开单科室名称
     诊断区：断链类型诊断 / 具体排查与补配指引 / 拉链表已有配置区间参考
     影响区：影响事实明细行数 / 影响总金额

   口径说明   :
     - 时间基准：拉链区间比对用 [执行时间]，为空时以 [缴费时间] 兜底（与计算脚本一致）
     - 日粒度比对：CONVERT(VARCHAR(8), ..., 112) 规避 DATETIME 精度与 9999 极值问题
     - 职系白名单：1001 临床 / 1003 药剂 / 1004 医技 / 1005 麻风住院部 / 1021 行后
     - 源列零改造：编码类字段裸引用，不做 CAST/补零

   只读声明   : 纯 SELECT，无写操作、无临时表；全链路 WITH (NOLOCK)
   生成日期   : 2026-11-23
   来源       : 由 analyses/医疗服务项目开单科室未映射明细.sql 改造
                （原为 2026 年起全量 + 临时表双结果集，现改为按月 + 单结果集聚合）
   =============================================================================== */

DECLARE @year  INT = CAST('{year}'  AS INT);
DECLARE @month INT = CAST('{month}' AS INT);

DECLARE @start_time DATETIME = DATEFROMPARTS(@year, @month, 1);
DECLARE @end_time   DATETIME = DATEADD(MONTH, 1, @start_time);

WITH cte_bmb_bridge AS (
    -- 部门字典桥接：事实层数值主键 [开单科室代码] → HIS 业务编码
    SELECT
        b.[id]              AS DEPT_ID,
        b.[编码]            AS HIS_DEPT_CODE,
        b.[名称]            AS HIS_DEPT_NAME
    FROM dbo.[sjjk_bmb_2025_06_01] AS b WITH (NOLOCK)
),
cte_rvu_scope AS (
    -- 仅保留纳入积分体系的收费项目（与计算脚本同口径：剔除 1101 出入院服务类 / 1041 诊察类）
    SELECT DISTINCT
        v.[PROJ_CODE]       AS PROJ_CODE
    FROM dbo.[DIM_PRF_ITEM_RVU_VERSION] AS v WITH (NOLOCK)
    WHERE v.[ITEM_CAT_CODE] NOT IN ('1101', '1041')
      AND v.[PROJ_CODE] IS NOT NULL
),
cte_dept_unit_mapping AS (
    -- HIS 科室 → 核算单元 拉链维表（原始透传，不做开窗折叠）
    SELECT
        m.[HIS_DEPT_CODE],
        m.[HPS_DEPT_CODE],
        m.[START_DATE],
        m.[END_DATE]
    FROM dbo.[sjjk_DEPT_UNIT_MAPPING_2025_11_27] AS m WITH (NOLOCK)
    WHERE m.[PERFORM_PERSON_TYPE_CODE] IN ('1001', '1003', '1004', '1005', '1021')
),
cte_configured AS (
    -- 已配置编码清单（用于区分“映射未配置”与“时间区间不匹配”）
    SELECT DISTINCT
        c.[HIS_DEPT_CODE]   AS HIS_DEPT_CODE
    FROM dbo.[sjjk_DEPT_UNIT_MAPPING_2025_11_27] AS c WITH (NOLOCK)
    WHERE c.[PERFORM_PERSON_TYPE_CODE] IN ('1001', '1003', '1004', '1005', '1021')
      AND c.[HIS_DEPT_CODE] IS NOT NULL
),
cte_config_span AS (
    -- 已配置区间参考（供业务直接照单补配/扩期）
    SELECT
        s.[HIS_DEPT_CODE]   AS HIS_DEPT_CODE,
        MIN(s.[START_DATE]) AS SPAN_START_DATE,
        MAX(s.[END_DATE])   AS SPAN_END_DATE,
        COUNT(1)            AS CONFIG_ROW_CNT
    FROM dbo.[sjjk_DEPT_UNIT_MAPPING_2025_11_27] AS s WITH (NOLOCK)
    WHERE s.[PERFORM_PERSON_TYPE_CODE] IN ('1001', '1003', '1004', '1005', '1021')
      AND s.[HIS_DEPT_CODE] IS NOT NULL
    GROUP BY s.[HIS_DEPT_CODE]
),
cte_fact AS (
    -- 事实明细：按 [开单时间] 限定当月
    SELECT
        f.[开单科室代码]                          AS DEPT_ID,
        f.[开单科室]                              AS DEPT_NAME,
        f.[开单时间]                              AS ORDER_TIME,
        f.[执行时间]                              AS EXEC_TIME,
        f.[缴费时间]                              AS PAY_TIME,
        f.[项目代码]                              AS PROJ_CODE,
        CAST(f.[金额] AS DECIMAL(18,8))           AS AMOUNT
    FROM dbo.[PF临时医疗服务项目26A] AS f WITH (NOLOCK)
    INNER JOIN cte_rvu_scope AS r
        ON f.[项目代码] = r.[PROJ_CODE]
    WHERE 1 = 1
      AND f.[开单时间] >= @start_time
      AND f.[开单时间] <  @end_time
),
cte_diag AS (
    -- 三层断链判定（字典缺失 → 映射未配置 → 时间区间不匹配）
    SELECT
        k.[DEPT_ID],
        k.[DEPT_NAME],
        k.[HIS_DEPT_CODE],
        k.[AMOUNT],
        sp.[SPAN_START_DATE],
        sp.[SPAN_END_DATE],
        sp.[CONFIG_ROW_CNT],
        CASE
            WHEN k.[HIS_DEPT_CODE] IS NULL   THEN N'字典缺失'
            WHEN cfg.[HIS_DEPT_CODE] IS NULL THEN N'映射未配置'
            ELSE N'时间区间不匹配'
        END AS BREAK_TYPE
    FROM (
        SELECT
            f.[DEPT_ID], f.[DEPT_NAME], f.[AMOUNT],
            b.[HIS_DEPT_CODE], f.[EXEC_TIME], f.[PAY_TIME]
        FROM cte_fact AS f
        LEFT JOIN cte_bmb_bridge AS b
            ON f.[DEPT_ID] = b.[DEPT_ID]
    ) AS k
    LEFT JOIN cte_configured AS cfg
        ON k.[HIS_DEPT_CODE] = cfg.[HIS_DEPT_CODE]
    LEFT JOIN cte_config_span AS sp
        ON cfg.[HIS_DEPT_CODE] = sp.[HIS_DEPT_CODE]
    WHERE NOT EXISTS (
        SELECT 1
        FROM cte_dept_unit_mapping AS mx
        WHERE mx.[HIS_DEPT_CODE] = k.[HIS_DEPT_CODE]
          AND mx.[HPS_DEPT_CODE] IS NOT NULL
          AND CONVERT(VARCHAR(8), ISNULL(k.[EXEC_TIME], k.[PAY_TIME]), 112)
                >= CONVERT(VARCHAR(8), mx.[START_DATE], 112)
          AND CONVERT(VARCHAR(8), ISNULL(k.[EXEC_TIME], k.[PAY_TIME]), 112)
                <= CONVERT(VARCHAR(8), ISNULL(mx.[END_DATE], '9999-12-31'), 112)
    )
)
SELECT TOP (200)
    -- 定位区
    d.[DEPT_ID]                                                      AS [HIS科室ID],
    ISNULL(d.[HIS_DEPT_CODE], N'')                                    AS [HIS科室编码],
    ISNULL(d.[DEPT_NAME], N'')                                        AS [开单科室名称],
    -- 诊断区
    d.[BREAK_TYPE]                                                    AS [断链类型诊断],
    CASE
        WHEN d.[BREAK_TYPE] = N'字典缺失'
            THEN N'部门字典表(sjjk_bmb_2025_06_01)缺失开单科室代码：'
                 + ISNULL(CAST(d.[DEPT_ID] AS VARCHAR(20)), N'空')
                 + N' → 请在该表按 id 补录此科室行并填写 [编码]'
        WHEN d.[BREAK_TYPE] = N'映射未配置'
            THEN N'科室与核算单元映射表缺少 HIS科室编码：'
                 + ISNULL(d.[HIS_DEPT_CODE], N'空')
                 + N' → 请补配职系(1001/1003/1004/1005/1021)的映射行'
        WHEN d.[BREAK_TYPE] = N'时间区间不匹配'
            THEN N'映射表已有 HIS编码[' + ISNULL(d.[HIS_DEPT_CODE], N'')
                 + N']，但业务时间不在有效区间 → 请扩展 START_DATE / END_DATE 或补配当期行'
        ELSE N'未识别的断链类型，请核查判定逻辑'
    END                                                               AS [排查与补配指引],
    CASE
        WHEN d.[CONFIG_ROW_CNT] IS NULL THEN N'无任何配置'
        ELSE CONVERT(VARCHAR(19), d.[SPAN_START_DATE], 120)
             + N' ~ '
             + CASE WHEN d.[SPAN_END_DATE] IS NULL THEN N'长期有效(NULL)'
                    ELSE CONVERT(VARCHAR(19), d.[SPAN_END_DATE], 120) END
             + N' (配置 ' + CAST(d.[CONFIG_ROW_CNT] AS VARCHAR(11)) + N' 行)'
    END                                                               AS [拉链表已有配置区间参考],
    -- 影响区
    COUNT(1)                                                          AS [影响事实明细行数],
    CAST(SUM(d.[AMOUNT]) AS DECIMAL(18,8))                            AS [影响总金额]
FROM cte_diag AS d
GROUP BY
    d.[DEPT_ID],
    d.[DEPT_NAME],
    d.[HIS_DEPT_CODE],
    d.[BREAK_TYPE],
    d.[SPAN_START_DATE],
    d.[SPAN_END_DATE],
    d.[CONFIG_ROW_CNT]
ORDER BY
    [影响总金额] DESC,
    [影响事实明细行数] DESC,
    [HIS科室ID] ASC;
