#ifndef __BULLET_WIDGET_H__
#define __BULLET_WIDGET_H__

#include "VInt2.h"

class UBulletWidget
{
public:
	UBulletWidget();

	void Clear();

	void Init_fast(uint32_t id, const VInt2& dir, const VInt2& pos);
	void SetPosition_fast(const VInt2& pos);
	void SetDir_fast(const VInt2& dir);

	uint32_t GetID() const;
	const VInt2& GetDir() const;
	const VInt2& GetPosition() const;

private:
	uint32_t id_;
	VInt2 dir_;
	VInt2 pos_;
};

#endif // __BULLET_WIDGET_H__