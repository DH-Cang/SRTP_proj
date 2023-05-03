#include "Effects.h"
#include <XUtil.h>
#include <RenderStates.h>
#include <EffectHelper.h>
#include <DXTrace.h>
#include <Vertex.h>
#include <TextureManager.h>
#include <ModelManager.h>
#include "LightHelper.h"
using namespace DirectX;


class AtmosphereEffect::Impl
{

public:
    // 必须显式指定
    Impl() {
        XMStoreFloat4x4(&m_View, XMMatrixIdentity()); // ??
        XMStoreFloat4x4(&m_Proj, XMMatrixIdentity());
    }
    ~Impl() = default;

public:
    template<class T>
    using ComPtr = Microsoft::WRL::ComPtr<T>;

    std::unique_ptr<EffectHelper> m_pEffectHelper;

    std::shared_ptr<IEffectPass> m_pCurrEffectPass;
    ComPtr<ID3D11InputLayout> m_pCurrInputLayout;
    D3D11_PRIMITIVE_TOPOLOGY m_CurrTopology = D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST;

    ComPtr<ID3D11InputLayout> m_pVertexPosNormalTexLayout;

    XMFLOAT4X4 m_View, m_Proj;  // todo: delete ??
};

namespace
{
    // 单例
    static AtmosphereEffect* g_pInstance = nullptr;
}

AtmosphereEffect::AtmosphereEffect()
{
    if (g_pInstance)
        throw std::exception("AtmosphereEffect is a singleton!");
    g_pInstance = this;
    pImpl = std::make_unique<AtmosphereEffect::Impl>();
}

AtmosphereEffect::~AtmosphereEffect()
{
}

AtmosphereEffect::AtmosphereEffect(AtmosphereEffect&& moveFrom) noexcept
{
    pImpl.swap(moveFrom.pImpl);
}

AtmosphereEffect& AtmosphereEffect::operator=(AtmosphereEffect&& moveFrom) noexcept
{
    pImpl.swap(moveFrom.pImpl);
    return *this;
}

AtmosphereEffect& AtmosphereEffect::Get()
{
    if (!g_pInstance)
        throw std::exception("AtmosphereEffect needs an instance!");
    return *g_pInstance;
}


bool AtmosphereEffect::InitAll(ID3D11Device* device)
{
    if (!device)
        return false;

    if (!RenderStates::IsInit())
        throw std::exception("RenderStates need to be initialized first!");

    pImpl->m_pEffectHelper = std::make_unique<EffectHelper>();

    Microsoft::WRL::ComPtr<ID3DBlob> blob;

    pImpl->m_pEffectHelper->SetBinaryCacheDirectory(L"Shaders\\Cache\\", true); // TODO, no cache

    // ******************
    // 创建顶点着色器
    //
    HR(pImpl->m_pEffectHelper->CreateShaderFromFile("AtmosphereVS", L"Shaders\\Atmosphere.hlsl", device,
        "AtmosphereVS", "vs_5_0", nullptr, blob.GetAddressOf()));
    // 创建顶点布局
    HR(device->CreateInputLayout(VertexPosNormalTex::GetInputLayout(), ARRAYSIZE(VertexPosNormalTex::GetInputLayout()),
        blob->GetBufferPointer(), blob->GetBufferSize(), pImpl->m_pVertexPosNormalTexLayout.GetAddressOf()));

    // ******************
    // 创建像素着色器
    //
    HR(pImpl->m_pEffectHelper->CreateShaderFromFile("AtmospherePS", L"Shaders\\Atmosphere.hlsl", device,
        "AtmospherePS", "ps_5_0"));

    // ******************
    // 创建通道
    //
    EffectPassDesc passDesc;
    passDesc.nameVS = "AtmosphereVS";
    passDesc.namePS = "AtmospherePS";
    HR(pImpl->m_pEffectHelper->AddEffectPass("Atmosphere", device, &passDesc));
    {
        auto pPass = pImpl->m_pEffectHelper->GetEffectPass("Atmosphere");
        pPass->SetRasterizerState(RenderStates::RSNoCull.Get());
        pPass->SetDepthStencilState(RenderStates::DSSNoDepthTest.Get(), 0);
    }
    pImpl->m_pEffectHelper->SetSamplerStateByName("g_Sampler", RenderStates::SSLinearClamp.Get());

    // 设置调试对象名
#if (defined(DEBUG) || defined(_DEBUG)) && (GRAPHICS_DEBUGGER_OBJECT_NAME)
    SetDebugObjectName(pImpl->m_pVertexPosNormalTexLayout.Get(), "AtmosphereEffect.VertexPosNormalTexLayout");
#endif
    pImpl->m_pEffectHelper->SetDebugObjectName("AtmosphereEffect");

    return true;
}

void AtmosphereEffect::SetRenderDefault()
{
    pImpl->m_pCurrEffectPass = pImpl->m_pEffectHelper->GetEffectPass("Atmosphere");
    pImpl->m_pCurrInputLayout = pImpl->m_pVertexPosNormalTexLayout;
    pImpl->m_CurrTopology = D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
}


void XM_CALLCONV AtmosphereEffect::SetWorldMatrix(DirectX::FXMMATRIX W)
{
    UNREFERENCED_PARAMETER(W);
}

void XM_CALLCONV AtmosphereEffect::SetViewMatrix(DirectX::FXMMATRIX V)
{
    XMStoreFloat4x4(&pImpl->m_View, V);
}

void XM_CALLCONV AtmosphereEffect::SetProjMatrix(DirectX::FXMMATRIX P)
{
    XMStoreFloat4x4(&pImpl->m_Proj, P);
}

MeshDataInput AtmosphereEffect::GetInputData(const MeshData& meshData)
{
    MeshDataInput input;
    input.pInputLayout = pImpl->m_pCurrInputLayout.Get();
    input.topology = pImpl->m_CurrTopology;
    input.pVertexBuffers = {
        meshData.m_pVertices.Get(),
        meshData.m_pNormals.Get(),
        meshData.m_pTexcoordArrays.empty() ? nullptr : meshData.m_pTexcoordArrays[0].Get()
    };
    input.strides = { 12, 12, 8 };
    input.offsets = { 0, 0, 0 };

    input.pIndexBuffer = meshData.m_pIndices.Get();
    input.indexCount = meshData.m_IndexCount;

    return input;
}

// TODO: set texture in shader
void AtmosphereEffect::SetMaterial(const Material& material)
{
    /*TextureManager& tm = TextureManager::Get();

    const std::string& str = material.Get<std::string>("$Skybox");
    pImpl->m_pEffectHelper->SetShaderResourceByName("g_SkyboxTexture", tm.GetTexture(str));*/
}


// TODO: update constant buffer
void AtmosphereEffect::Apply(ID3D11DeviceContext* deviceContext)
{
    /*XMMATRIX VP = XMLoadFloat4x4(&pImpl->m_View) * XMLoadFloat4x4(&pImpl->m_Proj);
    VP = XMMatrixTranspose(VP);
    pImpl->m_pEffectHelper->GetConstantBufferVariable("g_ViewProj")->SetFloatMatrix(4, 4, (const FLOAT*)&VP);*/

    pImpl->m_pCurrEffectPass->Apply(deviceContext);
}

void AtmosphereEffect::SetRenderTargetSize(int width, int height)
{
    pImpl->m_pEffectHelper->GetConstantBufferVariable("g_RenderTargetWidth")->SetSInt(width);
    pImpl->m_pEffectHelper->GetConstantBufferVariable("g_RenderTargetHeight")->SetSInt(height);
}

void AtmosphereEffect::SetTime(float time)
{
    pImpl->m_pEffectHelper->GetConstantBufferVariable("g_Time")->SetFloat(time);
}

void AtmosphereEffect::SetDepthTexture(ID3D11ShaderResourceView* depthTexture)
{
    pImpl->m_pEffectHelper->SetShaderResourceByName("g_DepthTexture", depthTexture);
}

void AtmosphereEffect::SetLitTexture(ID3D11ShaderResourceView* litTexture)
{
    pImpl->m_pEffectHelper->SetShaderResourceByName("g_LitTexture", litTexture);
}

void AtmosphereEffect::SetCameraLookAt(const DirectX::XMFLOAT3& cameraLookAt)
{
    pImpl->m_pEffectHelper->GetConstantBufferVariable("g_CameraLookAt")->SetFloatVector(3, (FLOAT*)&cameraLookAt);
}

void AtmosphereEffect::SetLightDir(const DirectX::XMFLOAT3& lightDir)
{
    pImpl->m_pEffectHelper->GetConstantBufferVariable("g_LightDir")->SetFloatVector(3, (FLOAT*)&lightDir);

}

void AtmosphereEffect::SetCameraRight(const DirectX::XMFLOAT3& cameraRight)
{
    pImpl->m_pEffectHelper->GetConstantBufferVariable("g_CameraRight")->SetFloatVector(3, (FLOAT*)&cameraRight);
}
