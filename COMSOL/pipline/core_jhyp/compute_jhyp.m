function lc_out = compute_jhyp(model, lc, p)
%COMPUTE_JHYP J_hyp 计算流水线（H001: source.model born -> full_maxwell）
%   lc_out = compute_jhyp(model, lc, p)
%
%   H001 (2026-07-22): 将 J_hyp 等效源模型从 Born 近似切换为 COMSOL 全波计算。
%     旧路径 (Born)  : equivalent_source + lightcone_hyp（质心体积求和，
%                      假设 E_inc ≈ E_total，ka=2.72 下引入 ~0.11 系统残差）
%     新路径 (Full)  : compute_jhyp_comsol（COMSOL mphint2 Gauss 积分 +
%                      横向投影，无 Born 偏差）
%   动机: 消除 V5a 标记的 Born 固有偏差，提升 cos θ 天花板。
%
%   输入:
%       model   COMSOL 模型对象（须已由调用方完成 solve_forward）
%       lc      LightConeData（含 k_dir；J_hyp_perp 将被更新）
%       p       config
%   输出:
%       lc_out  LightConeData（含更新的 J_hyp_perp）

fprintf('========== J_hyp 计算 (H001: COMSOL 全波) ==========\n');

% H001: COMSOL 全波 J_hyp（FEM 体积 Gauss 积分 + 横向投影），替代 Born 链
J_hyp = compute_jhyp_comsol(model, lc, p);

% 更新输出
lc_out = lc;
lc_out.J_hyp_perp = J_hyp;

fprintf('========== J_hyp 计算完成 (H001: COMSOL 全波) ==========\n');

end
