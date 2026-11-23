/* ===============================================================================
   Relative Path : precheck/门诊诊察类项目执行积分_小儿科_小儿科门诊医生核算单元未匹配.sql

   规则用途   : 「核算项校验规则」——执行前拦截“门诊诊察类（1043，小儿科=执行科室36）执行人员未匹配到核算单元”的数据
   归属核算项 : 一次分配/门诊诊察类项目执行积分_小儿科.sql
                （执行人员核算单元为空时，该部分工作量归属为「未匹配」，医生侧金额漏计）
   规则名称   : 小儿科门诊医生核算单元未匹配
   建议级别   : BLOCK（人员归属不明会导致医生核算单元金额失真）
   建议超时   : 90 秒
   建议行数   : 200

   参数占位符 : '{year}' / '{month}'（按 [接诊时间] 落在该自然月）
   判定规则   : **返回行数 > 0 即命中**

   断链四类（互斥，按顺序判定）:
     ① 人员表未更新        sjjk_ryb_2025_06_01 无该 [执行人员代码]
     ② 主数据未映射        MAP_MDM_STAFF 未配置该原始工号
     ③ 岗位系数表未配置     ads_dept_post_coefficient_m 当期无该员工记录
     ④ 核算单元为空        记录存在但 unit_code 为空/空白

   输出列（按“人事照着补”的动线排序）:
     人员定位区：执行人员代码 / 执行人员 / 原始系统工号 / 主数据标准工号
     诊断区    ：核算单元匹配状态 / 排查与补配指引
     影响区    ：涉及项目工作量件数

   口径说明   :
     - 项目范围：仅 1043 门诊诊察类（与计算脚本同口径）
     - 科室范围：排除 [执行科室代码] = 36（与计算脚本一致）
     - 执行人员黑名单：123 / 2343 / 2523（与计算脚本一致，剔除测试或特殊账号）
     - 时间基准：[接诊时间]（2026-09-30 计算脚本由执行时间改为接诊时间），闭区间
     - 来源过滤：[来源] = N'门诊'（与计算脚本一致，排除住院等来源）

   只读声明   : 纯 SELECT，无写操作；全链路 WITH (NOLOCK)
   生成日期   : 2026-11-23
   来源       : 由 analyses/门诊医生工作量核算单元未匹配明细.sql 改造
                （原为全量按月分组，现改为按核算年月过滤 + 单月输出）
   =============================================================================== */

DECLARE @year  INT = CAST('{year}'  AS INT);
DECLARE @month INT = CAST('{month}' AS INT);

-- 当月闭区间（与计算脚本 '{start_time}' / '{end_time}' 语义一致）
DECLARE @start_time DATETIME = DATEFROMPARTS(@year, @month, 1);
DECLARE @end_time   DATETIME = DATEADD(SECOND, -1, DATEADD(MONTH, 1, @start_time));

WITH cte_rvu AS (
    -- 仅取门诊诊察类（1043）收费项目
    SELECT
        v0.[PROJ_CODE]              AS PROJ_CODE
    FROM dbo.[DIM_PRF_ITEM_RVU_VERSION] AS v0 WITH (NOLOCK)
    WHERE v0.[PROJ_CODE] IS NOT NULL
      AND v0.[ITEM_CAT_CODE] = '1043'
    GROUP BY v0.[PROJ_CODE]
),
cte_ryb AS (
    SELECT
        r.[id]                      AS id,
        MAX(r.[编号])               AS src_staff_code,
        MAX(r.[姓名])               AS src_staff_name
    FROM dbo.[sjjk_ryb_2025_06_01] AS r WITH (NOLOCK)
    WHERE r.[id] IS NOT NULL
    GROUP BY r.[id]
),
cte_mdm_staff AS (
    SELECT
        s.[SRC_STAFF_CODE]          AS src_staff_code,
        MAX(s.[STAFF_CODE])         AS staff_code,
        MAX(s.[STAFF_NAME])         AS staff_name
    FROM dbo.[MAP_MDM_STAFF] AS s WITH (NOLOCK)
    WHERE s.[SRC_STAFF_CODE] IS NOT NULL
    GROUP BY s.[SRC_STAFF_CODE]
),
cte_staff_post AS (
    SELECT
        m.[staff_code]              AS staff_code,
        m.[year]                    AS [year],
        m.[month]                   AS [month],
        MIN(m.[unit_code])          AS unit_code,
        MIN(m.[unit_name])          AS unit_name
    FROM dbo.[ads_dept_post_coefficient_m] AS m WITH (NOLOCK)
    WHERE m.[staff_code] IS NOT NULL
    GROUP BY m.[staff_code], m.[year], m.[month]
),
cte_exec_fact AS (
    -- 门诊诊察类执行人员工作量（限定核算年月）
    SELECT
        f.[执行人员代码]             AS exec_staff_id,
        MAX(f.[执行人员])            AS exec_staff_name,
        COUNT(1)                    AS item_cnt
    FROM dbo.[PF临时医疗服务项目26A] AS f WITH (NOLOCK)
    INNER JOIN cte_rvu AS v
        ON f.[项目代码] = v.[PROJ_CODE]
    WHERE 1 = 1
      AND f.[执行科室代码] = 36
      AND f.[执行人员代码] IS NOT NULL
      -- 执行人员黑名单剔除（与计算脚本一致）
      AND f.[执行人员代码] NOT IN (123, 2343, 2523)
      AND f.[接诊时间] >= @start_time
      AND f.[接诊时间] <= @end_time
      AND f.[来源] = N'门诊'
    GROUP BY f.[执行人员代码]
)
SELECT TOP (200)
    -- 人员定位区
    fa.[exec_staff_id]                                  AS [执行人员代码],
    fa.[exec_staff_name]                                AS [执行人员],
    ryb.[src_staff_code]                                AS [原始系统工号],
    ISNULL(mdm.[staff_code], N'未映射')                  AS [主数据标准工号],
    -- 诊断区
    CASE
        WHEN ryb.[src_staff_code] IS NULL THEN N'人员表未更新（sjjk_ryb 无此 id）'
        WHEN mdm.[staff_code] IS NULL     THEN N'主数据未映射（MAP_MDM_STAFF 未配置）'
        WHEN sp.[staff_code] IS NULL      THEN N'岗位系数表未配置（当期无记录）'
        ELSE N'核算单元为空（记录存在但 unit_code 为 NULL）'
    END                                                 AS [核算单元匹配状态],
    CASE
        WHEN ryb.[src_staff_code] IS NULL
            THEN N'请在人员表 sjjk_ryb_2025_06_01 补录该 [执行人员代码]'
        WHEN mdm.[staff_code] IS NULL
            THEN N'请在员工工号对照表 MAP_MDM_STAFF 配置该原始工号 → 标准工号'
        WHEN sp.[staff_code] IS NULL
            THEN N'请在「科室岗位系数月度明细表」补录该员工当期记录（含核算单元）'
        ELSE N'该员工当期记录的核算单元编码为空，请在岗位系数表补齐 unit_code'
    END                                                 AS [排查与补配指引],
    -- 影响区
    CAST(fa.[item_cnt] AS DECIMAL(18,8))                AS [涉及项目工作量件数]
FROM cte_exec_fact AS fa
LEFT JOIN cte_ryb AS ryb
    ON fa.[exec_staff_id] = ryb.[id]
LEFT JOIN cte_mdm_staff AS mdm
    ON ryb.[src_staff_code] = mdm.[src_staff_code]
LEFT JOIN cte_staff_post AS sp
    ON mdm.[staff_code] = sp.[staff_code]
   AND @year  = sp.[year]
   AND @month = sp.[month]
WHERE sp.[unit_code] IS NULL
   OR LTRIM(RTRIM(sp.[unit_code])) = N''
ORDER BY
    [涉及项目工作量件数] DESC,
    [执行人员代码] ASC;
