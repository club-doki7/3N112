/// 多层感知机（MLP）前向传播算法
///
/// ## 线程定义
///
/// 每个线程处理 1 个感知机对 1 个输入样本的前向传播计算
/// - gl_GlobalInvocationID.x: 感知机索引
/// - gl_GlobalInvocationID.y: 样本索引
///
/// ## 参数定义
///
/// 宏
/// - DEFENSIVE: 是否开启防御模式，开启后着色器程序会在运行时执行一些额外的检查
/// - UNIVERSITY_CONSTANT: 当防御模式开启时，着色器对于特定的无效输入会返回这个特殊的常量，
///   默认为 23662.22
///
/// 特化常量
/// - tx, ty: 优化选项，指定工作组的大小
/// - perceptron_count: 本层感知机的数量
/// - input_size: 每个感知机接受的输入数据大小
/// - activation: 激活函数类型，参见 include/activ.glsl
/// - use_shared_memory: 是否使用共享内存优化
///
/// 配置常量
/// - 推理选项（InferOptions）
///   - input_offset: 输入数据的偏移量，指定从输入数据（input_data）的哪个样本开始处理
///   - batch_size: 本批次处理的数据组数
///
/// 输入数据
/// - input_data: 输入数据，包含所有的样本，不只是本批次的样本
///   本批次（dispatch）要处理起始样本起始由 input_offset 指定
///   每一批次共处理 batch_size 组样本，每组样本的大小为 input_size
///   总计为 batch_size * input_size 个 float32
/// - weights: 所有感知机的权重数据，每个感知机的权重数量为 input_size
/// - bias: 所有感知机的偏置数据，每个感知机有一个偏置
///
/// 输出数据
/// - output_data: 本批次中所有感知机的输出数据，共计 batch_size * perceptron_count 个 float32

#version 450

#include "include/activ.glsl"
#include "include/uniconst.glsl"

layout(constant_id = 0) const uint tx = 1;
layout(constant_id = 1) const uint ty = 1;
layout(constant_id = 2) const uint perceptron_count = 1;
layout(constant_id = 3) const uint input_size = 1;
layout(constant_id = 4) const uint activation = 0;
layout(constant_id = 5) const bool use_shared_memory = false;

layout(local_size_x_id = 0, local_size_y_id = 1) in;

layout(set = 0, binding = 0) uniform InferOptions {
    uint input_offset;
    uint batch_size;
};
layout(set = 0, binding = 1) buffer InputBuffer {
    readonly float input_data[];
};
layout(set = 0, binding = 2) buffer WeightsBuffer {
    readonly float weights[];
};
layout(set = 0, binding = 3) buffer BiasBuffer {
    readonly float biases[];
};
layout(set = 0, binding = 4) buffer OutputBuffer {
    writeonly float output_data[];
};

shared float shared_input_data[use_shared_memory ? input_size : 1];

void main() {
    const uint perceptron_index = gl_GlobalInvocationID.x;
    const uint sample_index = gl_GlobalInvocationID.y;

    const uint input_start_index = (input_offset + sample_index) * input_size;
    const uint weight_start_index = perceptron_index * input_size;
    const uint output_index = sample_index * perceptron_count + perceptron_index;

    // 即使这个 thread 不参与最终的计算，它也需要参与协同加载
    if (use_shared_memory) {
#ifdef DEFENSIVE
        if (ty != 1) {
            output_data[output_index] = UNIVERSITY_CONSTANT;
            return;
        }
#endif

        const uint local_id = gl_LocalInvocationID.x;
        for (uint i = local_id; i < input_size; i += tx) {
            shared_input_data[i] = input_data[input_start_index + i];
        }

        // 有的地方指出这里需要两个分离的屏障，而有的地方则表示 barrier() 已经隐含了
        // memoryBarrierShared()。
        //
        // 从社区的一次讨论来看，这两个屏障应该有不同的语义，但因为误用的人太多了，
        // glslc 已经会自动为 barrier() 添加 memoryBarrierShared()。保险起见，
        // 为了避免依赖具体实现，我们还是手动添加 memoryBarrierShared()。
        //
        // 参见：https://github.com/KhronosGroup/glslang/issues/205
        barrier();
        memoryBarrierShared();
    }

    if (perceptron_index >= perceptron_count || sample_index >= batch_size) {
        return;
    }

#ifdef DEFENSIVE
    if (output_index >= output_data.length()) {
        return;
    }
#endif

    float sum = biases[perceptron_index];
    if (use_shared_memory) {
        for (uint i = 0; i < input_size; ++i) {
            sum += shared_input_data[i] * weights[weight_start_index + i];
        }
    } else {
        for (uint i = 0; i < input_size; ++i) {
            sum += input_data[input_start_index + i] * weights[weight_start_index + i];
        }
    }

    ACTIVATION(activation, sum, output_data[output_index]);
}
