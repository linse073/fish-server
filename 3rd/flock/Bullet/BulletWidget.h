#ifndef __BULLET_WIDGET_H__
#define __BULLET_WIDGET_H__

#include "VInt2.h"

namespace KBEngine
{
	class MemoryStream;
}

class UBulletWidget
{
public:
	UBulletWidget();

	void Clear();

	void Init_fast(uint32_t id, uint32_t kind, const VInt2& dir, const VInt2& pos, uint8_t index, uint32_t multi, uint32_t costGold);
	void SetPosition_fast(const VInt2& pos);
	void SetDir_fast(const VInt2& dir);
	void Pack_Data(KBEngine::MemoryStream& stream);

	uint32_t GetID() const;
	const VInt2& GetDir() const;
	const VInt2& GetPosition() const;
	uint32_t GetMulti() const;
	uint32_t GetKind() const;

private:
	uint32_t id_;
	uint8_t index_;
	VInt2 dir_;
	VInt2 pos_;
	uint32_t multi_;
	uint32_t kind_;
	uint32_t costGold_;
};

#endif // __BULLET_WIDGET_H__