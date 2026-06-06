import numpy as np
from scipy.optimize import minimize
from itertools import product

def find_best_quantities():
    # ===== 数据区（直接在这里添加或删减数据，无需改代码） =====
    # 单价列表
    prices = np.array([2398.0, 2997.5, 5341.0, 1471.5, 861.1])
    # 最大数量限制
    max_quantities = np.array([292.08, 292.07, 18.13, 218.738, 84.817])
    # 目标总金额
    target_total = 871637.99
    # 数量保留的小数位数
    step = 0.001
    # ====================================================

    num_items = len(prices)  # 自动识别产品个数

    # 定义优化目标函数
    def objective_func(x):
        current_total = np.sum(x * prices)
        return (current_total - target_total) ** 2

    # 设置约束条件 (0 <= x_i <= max_quantities)
    bounds = [(0.0, max_q) for max_q in max_quantities]

    # 第一步：寻找连续实数域上的最优解
    initial_guess = max_quantities / 2
    result = minimize(objective_func, initial_guess, bounds=bounds, method='L-BFGS-B')

    if not result.success:
        print("警告：连续优化未完全收敛，将使用当前最优值。")

    continuous_opt = result.x

    # 第二步：自适应离散搜索
    # 产品数量越多，暴力穷举的计算量会指数级增加。
    # 这里引入自适应搜索半径：产品少时搜索大范围，产品多时搜索小范围
    if num_items <= 4:
        search_radius = 12     # 4个以内可以搜大一点
    elif num_items <= 6:
        search_radius = 8      # 5~6个产品
    elif num_items <= 8:
        search_radius = 5      # 7~8个产品
    else:
        search_radius = 3      # 超过8个产品，建议仅微调邻域
    
    best_error = float('inf')
    best_quantities = None

    # 生成候选值网格
    candidate_values = []
    for i in range(num_items):  # 关键修改1：使用 num_items 替代 4
        low = max(0, continuous_opt[i] - search_radius * step)
        high = min(max_quantities[i], continuous_opt[i] + search_radius * step)
        
        # 生成候选数组
        values = np.arange(low, high + step/2, step)
        values = np.round(values, 3)
        # 去除重复值或空数组（避免出错）
        if len(values) == 0:
            values = np.array([0.0])  
        candidate_values.append(values)

    print(f"正在计算 {num_items} 个产品的最优离散解，搜索半径={search_radius}步长，请稍候...")
    
    # 遍历组合，关键修改2：直接使用 combo 元组转为 numpy 数组，不硬解包
    for combo in product(*candidate_values):
        x = np.array(combo)  # 自动适应产品个数
        
        # current_total = np.sum(x * prices)
        current_total = np.sum(np.round(x * prices, 2)) # 计算当前总金额，保留两位小数以减少浮点误差
        error = abs(current_total - target_total)
        
        if error < best_error:
            best_error = error
            best_quantities = x

    # 输出结果
    print("\n" + "="*30)
    print("计算结果：")
    print(f"目标总金额：{target_total}")
    print(f"当前计算总金额：{np.sum(best_quantities * prices):.3f}")
    print(f"绝对误差：{best_error:.4f}")
    print("-" * 30)
    print("各产品的销售数量为：")
    for i, qty in enumerate(best_quantities):
        print(f"产品 {i+1}: {qty:.3f} (单价: {prices[i]}, 最大限制: {max_quantities[i]})")
    print("="*30)
    
    return best_quantities

if __name__ == "__main__":
    find_best_quantities()