/* ===============================================================================
   Relative Path : precheck/医疗服务项目开单积分_未配置RVU点数项目.sql

   规则用途   : 「核算项校验规则」——执行前拦截“有业务发生但未配置 RVU 点数”的收费项目
   归属核算项 : 一次分配/医疗服务项目开单积分.sql
                （RVU 点数缺失时该项目无法计算点数，直接导致开单积分漏算）
   规则名称   : 未配置RVU点数项目
   建议级别   : BLOCK（点数缺失=该部分业务无法参与核算，属实质性漏算）
   建议超时   : 60 秒
   建议行数   : 200

   参数占位符 : '{year}' / '{month}'（核算年月，扫描该自然月内发生的开单记录）
   判定规则   : **返回行数 > 0 即命中**（有行=存在未配置项目，0 行=通过）

   输出列设计（按“维护人补配置”的动线排序）:
     识别区：项目大类 / 项目代码 / 项目名称
     参考区：开单记录笔数 / 累计发生数量 / 累计涉及金额 / 首次开单时间 / 最近开单时间
     缺口区：缺口类型 / 说明
     —— 前 3 列与 DIM_PRF_ITEM_RVU_VERSION 的 PROJ_CODE/PROJ_NAME 对齐，便于照单补录

   只读声明   : 纯 SELECT，无写操作；全链路 WITH (NOLOCK)
   生成日期   : 2026-11-23
   来源       : 由 analyses/未配置RVU点数项目排查清单.sql 改造
                （原为“2025-01-01 起”全量排查，现改为按核算年月扫描 + 前 3 列对齐维表）
   =============================================================================== */

DECLARE @year  INT = CAST('{year}'  AS INT);
DECLARE @month INT = CAST('{month}' AS INT);

DECLARE @start_time DATETIME = DATEFROMPARTS(@year, @month, 1);
DECLARE @end_time   DATETIME = DATEADD(MONTH, 1, @start_time);

SELECT TOP (200)
    -- 识别区：与 RVU 维表维护口径对齐，便于照单补录
    s.[项目大类]                                     AS [项目大类],
    s.[项目代码]                                     AS [项目代码],
    s.[项目名称]                                     AS [项目名称],
    -- 参考区：判断优先级（先补金额/数量大的）
    CAST(s.[开单记录笔数] AS DECIMAL(18,8))           AS [开单记录笔数],
    CAST(s.[累计发生数量] AS DECIMAL(18,8))           AS [累计发生数量],
    CAST(s.[累计涉及金额] AS DECIMAL(18,8))           AS [累计涉及金额],
    CONVERT(VARCHAR(19), s.[首次开单时间], 120)       AS [首次开单时间],
    CONVERT(VARCHAR(19), s.[最近开单时间], 120)       AS [最近开单时间],
    -- 缺口区：说明缺什么、后果
    N'未配置RVU点数'                                  AS [缺口类型],
    N'该项目在DIM_PRF_ITEM_RVU_VERSION中无配置，开单积分无法计算' AS [说明]
FROM (
    SELECT
        src.[项目大类]                                                AS 项目大类,
        src.[项目代码]                                                AS 项目代码,
        src.[项目名称]                                                AS 项目名称,
        COUNT(1)                                                      AS 开单记录笔数,
        CAST(SUM(CAST(src.[数量] AS DECIMAL(18,8))) AS DECIMAL(18,8))  AS 累计发生数量,
        CAST(SUM(CAST(src.[金额] AS DECIMAL(18,8))) AS DECIMAL(18,8))  AS 累计涉及金额,
        MIN(src.[开单时间])                                            AS 首次开单时间,
        MAX(src.[开单时间])                                            AS 最近开单时间
    FROM dbo.[PF临时医疗服务项目26A] AS src WITH (NOLOCK)
    WHERE 1 = 1
      AND src.[开单时间] >= @start_time
      AND src.[开单时间] <  @end_time
      AND src.[项目代码] IS NOT NULL
      -- 非核算项目大类剔除
      AND (
          src.[项目大类] NOT IN (N'西药费', N'中草药费', N'中成药费', N'卫生材料费', N'卫生材料')
          OR src.[项目大类] IS NULL
      )
      -- 院外项目剔除
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.[DIM_OUT_HOSP_ITEM] AS out_item WITH (NOLOCK)
          WHERE out_item.[ITEM_CODE] = src.[项目代码]
      )
      -- RVU 未配置判定（存在性语义，不 JOIN 维表属性，防行数膨胀）
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.[DIM_PRF_ITEM_RVU_VERSION] AS rvu WITH (NOLOCK)
          WHERE rvu.[PROJ_CODE] = src.[项目代码]
      )
    GROUP BY
        src.[项目大类],
        src.[项目代码],
        src.[项目名称]
) AS s
ORDER BY
    s.[累计涉及金额] DESC,
    s.[累计发生数量] DESC,
    s.[项目代码] ASC;
